# finops-terminal — architecture

**Status:** Proposal, 2026-10-17
**Based on:** [Bloomberg Terminal clean-room study](research/bloomberg-terminal-study.md)

finops-terminal is a keyboard-first **native macOS** market terminal (SwiftUI)
for a single user. It takes the *ideas* that make professional terminals fast —
command line, carried security context, linked multi-panel workspaces, one
field dictionary, streaming data layer — and builds them with its own
vocabulary and design. Data comes from yfinance, SEC EDGAR, FRED and Yahoo news
through a local Python process.

---

## 1. Goals and non-goals

**Goals**
1. Reach any screen for any security in a few keystrokes.
2. Stream live quotes to many panels without overloading providers.
3. Add a data provider or a screen without touching the rest of the system.
4. Expose the same data to the UI and exports through one field dictionary.
5. Keep provider quirks (rate limits, breakage, licensing) inside the data layer.

**Non-goals (v1)**
- Order execution / OMS.
- Chat network.
- Proprietary analytics models such as bond pricing (add later as modules).
- Bloomberg compatibility: no Bloomberg mnemonics, look or data.

## 2. System overview

```
┌────────────────── finops-terminal.app  (SwiftUI, macOS) ──────────────────┐
│  Workspace window                                                        │
│   ├─ Command line ──► Command parser ──► Function registry               │
│   ├─ Panel grid (N panels: loaded security, function, params, history)   │
│   ├─ Link groups (color-coded security sync between panels)              │
│   ├─ DataClient (actor: one WebSocket, request/subscribe, correlation)   │
│   └─ GatewayProcess (launches + supervises the sidecar, picks the port)  │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ WebSocket on 127.0.0.1:<random port>
┌───────────────────────────────────▼──────────────────────────────────────┐
│  Gateway sidecar  (Python 3.12 · FastAPI/uvicorn, child of the app)      │
│   ├─ Service router ── refdata | history | intraday | stream | lookup    │
│   │                    | fields | news | screen                          │
│   ├─ Subscription hub (dedupe topics, fan-out, conflation, polling)      │
│   ├─ Cache (memory for quotes; SQLite for series and fundamentals)       │
│   └─ Provider adapters ──► yfinance · SEC EDGAR · FRED · Yahoo news     │
└──────────────────────────────────────────────────────────────────────────┘
```

**Why a sidecar instead of pure Swift:** yfinance only exists in Python and
does a lot of work for us (cookies/crumb, symbol quirks, corporate-action
adjustments). Keeping all providers in one Python process also keeps provider
rules in one place. The app owns the sidecar's lifetime: it starts it on
launch with a random free port and a per-launch token, restarts it if it dies,
and stops it on quit. The socket binds to `127.0.0.1` only, and the token is
checked on connect.

## 3. Core domain

### 3.1 Security identity
- **Canonical ID:** FIGI where available (open standard, free lookup through
  OpenFIGI). Otherwise an internal ID.
- **Typed form** (what users type): `<symbol> [<venue>] <class>` — for example
  `AAPL US EQ`, `EURUSD FX`, `US10Y GOV`, `CL1 CMD`, `SPX IDX`.
  - Our own asset-class codes: `EQ`, `ETF`, `GOV`, `CORP`, `FX`, `CMD`, `IDX`,
    `CRYPTO`, `FUT`, `OPT`, `ECO` (macro series).
  - `venue` is optional; the resolver picks the primary listing.
- **Resolver** (`lookup` service): typed text → ranked candidates → canonical ID.

### 3.2 Field dictionary
The one vocabulary shared by screens, screeners, exports and the API.

```swift
struct FieldDef: Codable {   // mirrored as a Pydantic model in the gateway
  let id: String            // "price.last", "fund.revenue", "est.eps.fy1"
  let type: FieldType       // number | string | date | bool | money | percent
  let kind: FieldKind       // realtime | reference | historical | bulk
  let assetClasses: [AssetClass]
  let description: String
  let overrides: [OverrideDef]?   // e.g. currency, period, fiscal basis
  let providers: [ProviderPath]   // provider + path/tag candidates
}
```

- Fields are stored as data (`shared/fields/*.json`), loaded by the gateway and
  bundled into the app.
- A `fields` service exposes search and metadata, so users can ask what a
  field means and where it comes from.
- **Overrides** follow BLPAPI's idea: one field plus parameters, not a new field
  for every variation.

### 3.3 Data protocol (modeled on BLPAPI's public design)
One WebSocket per app window. Every message has a correlation ID. Messages
are JSON, decoded with `Codable` in Swift and Pydantic in Python.

```ts
// client → gateway
{ t: "request",   cid, service: "history", op: "series",
  params: { ids, fields, start, end, periodicity, overrides } }
{ t: "subscribe", cid, id, fields, intervalMs? }  // intervalMs = conflation
{ t: "unsubscribe", cid }

// gateway → client
{ t: "partial",  cid, data }        // progressive chunks
{ t: "response", cid, data }        // final chunk
{ t: "tick",     cid, data }        // subscription update (conflated)
{ t: "subStatus", cid, status: "started" | "stale" | "failed" | "terminated", reason? }
{ t: "error",    cid, code, message }
{ t: "sessionStatus", status }      // connected | degraded | reconnecting
```

**Services:**

| Service | Paradigm | Purpose |
|---|---|---|
| `refdata` | req/resp | Current field values for N securities × M fields |
| `history` | req/resp, partial | Daily/weekly/monthly series |
| `intraday` | req/resp, partial | Bars and ticks for a session window |
| `stream` | subscription | Live quote fields, conflated per subscriber |
| `lookup` | req/resp | Security search / resolve |
| `fields` | req/resp | Field search and metadata |
| `news` | req/resp + subscription | Headlines and stories by security or topic |
| `screen` | req/resp, partial | Run a screen (filters over fields) |

## 4. Gateway

- **Runtime:** a **Python 3.12+** process (FastAPI + uvicorn, asyncio) managed
  by `uv`, started by the app. In development the app runs
  `uv run --project gateway finops-gateway --port N --token T`. A release build
  bundles the gateway and a relocatable Python runtime inside the `.app`.
  Blocking libraries (yfinance) run in a thread pool through
  `asyncio.to_thread`.
- **Subscription hub:** each topic (`id × field set`) has one upstream
  subscription, no matter how many panels watch it. Fan-out applies each
  subscriber's conflation interval.
- **Provider adapters:**
  ```python
  class ProviderAdapter(Protocol):
      id: str
      capabilities: list[Capability]   # which services/fields/asset classes
      license: ProviderLicense         # display/redistribution/delay rules
      def request(self, op: Op, params: Params) -> AsyncIterator[Chunk]: ...
      def subscribe(self, topic: Topic) -> AsyncIterator[Tick]: ...  # optional
      def health(self) -> ProviderHealth: ...
  ```
  The router picks a provider for each field by capability, priority and
  health.
- **Caching:** an in-memory TTL cache per provider call (quotes 1–2 min,
  research 1 h, EDGAR facts 24 h, FRED 1 h). A persistent SQLite cache
  (`~/Library/Application Support/finops-terminal/cache.db`) is planned.
- **Rate limiting:** a token bucket for each provider key, with a queue and
  priority (interactive > background).

### 4.1 Providers (decided)
| Need | Provider | Adapter | Serves services |
|---|---|---|---|
| Market data (quotes, history, intraday, lookup) | **Yahoo Finance via `yfinance`** | `providers/yahoo` | `refdata` (price fields), `history`, `intraday`, `stream`, `lookup` |
| Fundamentals | **SEC EDGAR** (`data.sec.gov` JSON APIs: `companyfacts`, `companyconcept`, `submissions`) | `providers/edgar` | `refdata` (fund.* fields), `history` (fundamental series), filings for `DESC`/`EVT` |
| Macro / economics | **FRED** (St. Louis Fed API, `fredapi` or plain HTTP) | `providers/fred` | `history`, `lookup` (series search), `ECON` calendar via release dates |
| News | **Yahoo Finance** (`yfinance` `Ticker.news` / `Search`) | `providers/yahoo` | `news` |

**What each provider means for the design:**
- **yfinance is unofficial.** It scrapes Yahoo's endpoints and can break or be
  throttled without notice, and Yahoo's terms limit the data to personal use.
  For the gateway this means aggressive caching, a per-process rate limiter,
  backoff on HTTP 429, `subStatus: "stale"` when Yahoo stalls, and a pinned
  yfinance version with a contract test that runs daily. It also means
  **finops-terminal is a personal / non-redistributing tool** while it uses
  Yahoo (see §10). The adapter interface keeps a later move to a licensed feed
  local to one package.
- **Streaming:** use yfinance's WebSocket streamer (`yf.AsyncWebSocket`) for
  live quotes. If it's unavailable, fall back to polling `fast_info` every
  N seconds through the same `stream` service. Quotes may be delayed depending
  on the exchange; carry a `delayed`/`asOf` flag on every tick.
- **Identity:** Yahoo symbols (`AAPL`, `VOD.L`, `EURUSD=X`, `^GSPC`, `CL=F`,
  `BTC-USD`) map to and from our typed form in the gateway's `securities` module. EDGAR
  keys on **CIK**, so the resolver maps ticker → CIK with SEC's
  `company_tickers.json`, refreshed daily. EDGAR only covers SEC filers, so
  `FIN` reports "no fundamentals" for foreign listings instead of failing.
- **EDGAR rules:** send a descriptive `User-Agent` with a contact email (set in
  the app's Settings, never hard-coded) and stay under 10 requests/second. Cache
  `companyfacts` per CIK for 24h. XBRL tags (`us-gaap:Revenues`,
  `RevenueFromContractWithCustomer…`) differ across companies, so the field
  dictionary maps each `fund.*` field to an **ordered list of candidate
  tags**. The values also need fiscal-period normalization (10-K vs 10-Q,
  quarterly vs annual, and deriving Q4 as FY minus Q1–Q3).
- **FRED:** needs a free API key. The app stores it in the macOS Keychain and
  passes it to the sidecar through its environment. Series IDs
  (`CPIAUCSL`, `UNRATE`, `DGS10`…) become securities of class `ECO`, e.g.
  `UNRATE ECO`. That lets `CHART` and `HIST` work on macro series unchanged.
  Respect FRED's rate limit and cache series until the next release date.
- **News:** Yahoo headlines link out to publishers. Store and show only
  headline, source, time and link, never full article text.

## 5. App (SwiftUI)

### 5.1 Stack
- **SwiftUI, macOS 15+**, Swift 6 strict concurrency. State lives in
  `@Observable` models.
- **Swift Charts** for price charts, and `Table` for dense grids.
- **`URLSessionWebSocketTask`** inside a `DataClient` actor. It exposes
  `request(...) async throws -> Response` and
  `subscribe(...) -> AsyncStream<Tick>`, with correlation IDs internally.
- **Swift Package** layout: `FinopsCore` (protocol models, security parsing,
  command parser, DataClient), `FinopsUI` (shared views), and the `FinopsTerminal`
  executable app target. Core is unit-tested with Swift Testing and doesn't
  depend on SwiftUI.
- **No web view.** Everything is native.

### 5.2 Workspace model
```swift
@Observable final class Workspace { var name: String; var panels: [Panel]; var activePanel: Panel.ID? }
@Observable final class Panel: Identifiable {
  let id: UUID
  var function: FunctionID         // which function is mounted
  var security: Security?          // loaded security (context)
  var args: [String]
  var linkGroup: LinkGroup?        // red | blue | green | amber
  var history: [PanelState]        // back/forward within the panel
}
```
- Changing the security in a linked panel updates every panel in its group.
- Workspaces are saved as JSON in Application Support and restored on launch.
  Multiple windows are supported, one workspace per window.

### 5.3 Click-first navigation
The mouse is the primary way to navigate. The command line is an optional
shortcut for power users.
- **Sidebar:** a search box backed by the `lookup` service (debounced, click a
  result to open it, `+` to watch it) and a watchlist with live prices. The
  watchlist is persisted in `UserDefaults`.
- **Top bar:** back button, the loaded security, and function tabs
  (`1 QUOTE`, `2 CHART`, `?`) with ⌘1 / ⌘2 shortcuts.
- **Function controls are buttons**, for example the chart range bar
  (1D … MAX).
- **Look:** dense, dark, monospaced, with an amber accent for context and
  interactive elements. Inspired by professional terminals, but with no
  copied logos, screens or names.

### 5.4 Command line (optional)
Grammar (noun first, then verb, context carried):
```
[security] [function] [args…]  ⏎
AAPL US EQ CHART 1Y            → chart AAPL for 1 year in the active panel
CHART 5Y                       → re-chart the loaded security for 5 years
EURUSD FX                      → load security into active panel's default fn
FIN                            → financials for the loaded security
3                              → trigger numbered action 3 on the current screen
```
- **Parser:** tokens → try security resolution (longest match against the
  resolver plus the asset-class code) → function ID or alias → typed args by
  the function's param schema.
- **Palette:** if the parse fails, fuzzy search over functions (name, keywords,
  description), securities, fields and saved workspaces.

### 5.5 Global keys (same on every screen)
| Key | Action |
|---|---|
| `Enter` | Go (execute) |
| `Esc` | Cancel / clear command line |
| `⌘[` / `⌘]` | Back / forward in panel history |
| `⌘↑` | Up to the function's menu |
| `PgUp` / `PgDn` | Page |
| `F1` | Context help |
| `⌘K` | Command palette |
| `⌘1…9` | Focus panel N |
| `⌘L` | Focus the command line |
| `F2…F11` | Insert asset-class code (EQ, GOV, CORP, FX, CMD, IDX…) |
| digits + `Enter` | Numbered action on the current screen |

### 5.6 Function modules
Each screen is a self-contained module that the router mounts into a panel.
```swift
struct TerminalFunction {
  let id: FunctionID              // .chart
  let aliases: [String]           // ["CHART", "CH"]
  let title: String
  let keywords: [String]          // for palette search
  let needsSecurity: Bool
  let actions: [NumberedAction]   // "1) Compare  2) Indicators  3) Export"
  let makeView: @MainActor (PanelContext) -> AnyView
}
```
Each module talks only to the `DataClient`. It doesn't call providers
directly. Every module gets the shared
header (security, last price, change), the parameter strip, export, alerts and
help.

### 5.7 Function set (implemented)
Every screen is reachable by clicking (panel tabs, sidebar, buttons, table rows) and by
typing. Gateway "document" responses carry `cmd` strings on choice buttons and table
rows, so a click runs exactly the command a user would type.

| Command | Aliases | Job | Source |
|---|---|---|---|
| `QUOTE` | Q | Live quote, day stats | yfinance |
| `CHART` | CH, GP | Line/candles, volume, SMA/EMA/Bollinger, RSI, MACD, compare `VS` | yfinance |
| `DESC` | DES | Profile, valuation, margins, dividend | yfinance |
| `NEWS` | N | Headlines for a security or `NEWS <words>` | Yahoo |
| `FIN` | FA | Income statement, balance sheet, cash flow (`A`/`Q`, `IS`/`BS`/`CF`) | SEC EDGAR |
| `EST` | ANR | Ratings, price targets, EPS/revenue estimates, rating changes | yfinance |
| `EVT` | DIV, ERN | Next earnings, earnings history, dividends, splits | yfinance |
| `HOLD` | HDS | Institutions, funds, insider transactions | yfinance |
| `FILE` | FILINGS | 10-K/10-Q/8-K/insider/proxy filings with links | SEC EDGAR |
| `OPT` | OMON | Option chain by expiry | yfinance |
| `MKT` | WEI | Indices, rates, FX, commodities, crypto | yfinance |
| `MOVERS` | MOST | Gainers, losers, most active, … | yfinance screeners |
| `SCRN` | EQS | Equity screener (`MCAP>10B PE<20 SECTOR=…`) | yfinance |
| `ECON` | — | Macro dashboard + release calendar, `ECON <series> [range] [YOY]`, `ECON SEARCH` | FRED |
| `CURVE` | — | Treasury curve vs 1M / 6M / 1Y ago | FRED |
| `PORT` | — | Portfolio with live P&L (`<sec> PORT ADD <qty> [cost]`) | local + yfinance |
| `ALERT` | — | Price alerts with macOS notifications (`<sec> ALERT > 350`) | local + yfinance |
| `WATCH` | — | `<sec> WATCH` adds to the current watchlist (multiple watchlists) | local |

Workspace: 1, 2 or 4 panels (⌥⌘1/2/4). Linked panels follow the security loaded in any
other linked panel. ⌘1…⌘0 open the security functions in the active panel. Tables sort
by column, copy as TSV and export CSV.

### 5.8 Visual design
Dark appearance by default, and it follows the system setting. SF Mono with
`.monospacedDigit()` for numbers. Color only for meaning: up, down, editable,
stale, warning. Every color passes WCAG contrast. Uses its own palette, not
amber-on-black trade dress. Density settings (compact / comfortable).

## 6. Persistence
| Store | Owner | Contents |
|---|---|---|
| `~/Library/Application Support/finops-terminal/workspaces/*.json` | App | Workspaces, panels, link groups |
| `…/cache.db` (SQLite) | Gateway | Cached series, bars, fundamentals |
| `UserDefaults` | App | Settings (EDGAR contact email, density) |
| Keychain | App | FRED API key |

## 7. Exports (later)
Any table or chart can be copied as TSV or exported to CSV, using the same
field IDs as column names.

## 8. Repository layout
```
finops-terminal/
├─ app/                      Swift package (open Package.swift in Xcode)
│  ├─ Package.swift
│  ├─ Sources/
│  │  ├─ FinopsCore/         Protocol models, Security, CommandParser, DataClient
│  │  ├─ FinopsUI/           Workspace, panels, command line, functions (CHART, QUOTE…)
│  │  └─ FinopsTerminal/     @main App, GatewayProcess
│  └─ Tests/FinopsCoreTests/
├─ gateway/                  Python sidecar (uv project)
│  ├─ pyproject.toml
│  ├─ src/finops_gateway/    server, protocol, hub, providers/{yahoo,edgar,fred}
│  └─ tests/
├─ shared/fields/            Field dictionary (JSON), used by both
└─ docs/
```

## 9. Delivery phases
1. ✅ **Skeleton:** Swift package and Python gateway, `CHART` and `QUOTE`.
2. ✅ **Company & markets:** `DESC NEWS FIN EST EVT HOLD FILE OPT MKT MOVERS SCRN`.
3. ✅ **Macro:** `ECON` (dashboard, series, search, calendar) and `CURVE` via FRED.
4. ✅ **Workspace & tools:** 1/2/4 linked panels, `PORT`, `ALERT`, multiple
   watchlists, Settings (FRED key in Keychain), CSV export.
   Next: saved workspaces, command palette with fuzzy search, SQLite cache.
5. **Distribution:** bundled Python runtime inside the `.app`, signing and
   notarization, `PORT`.

## 10. Open decisions
- **Audience.** With yfinance and Yahoo news as sources, finops-terminal is a
  personal tool: their terms don't allow redistributing the data. Sharing it
  needs a licensed market-data and news feed. Only the `yahoo` adapter changes.
- **Packaging the sidecar** (phase 5): a relocatable CPython build such as
  python-build-standalone with a vendored venv, or a frozen binary
  (PyInstaller/Nuitka). Decide based on app size and signing friction.
