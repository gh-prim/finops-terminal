# Bloomberg Terminal — clean-room study

**Date:** 2026-10-17
**Method:** Clean room. This study uses only public material: Bloomberg's
published API documentation and SDK, public training and marketing material,
and widely described user behavior. Nothing here comes from decompiling,
disassembling or accessing Bloomberg software. finops-terminal must keep it that
way: don't copy Bloomberg code, screens, icons, data, trade dress or trademarks.

The goal is to understand *what problems the Terminal solves and which
interaction ideas make it effective*. Then finops-terminal can solve the same
problems in its own way.

---

## 1. What the product is

The Terminal is a subscription workstation for market professionals. It has
four layers:

| Layer | What it gives the user |
|---|---|
| **Data** | Real-time and historical prices across every asset class, reference data (corporate actions, fundamentals, estimates, ownership), economic series and news. |
| **Analytics** | Hundreds of single-purpose "functions": charting, relative value, screening, portfolio risk, fixed-income and derivatives pricing. |
| **Communication** | Instant Bloomberg (IB) chat and MSG email between subscribers. Much of its stickiness comes from this network. |
| **Execution / workflow** | Order and execution management (EMSX and others), alerts, and Excel and API integration. |

Its lasting value comes from **data breadth, speed of navigation and the
network**, not from any single screen.

## 2. Interaction model (the part worth learning from)

### 2.1 Command line as the primary input
Every screen is reached by typing into a command line. The canonical grammar is:

```
<security>  <market sector>  <function>  <GO>
IBM US      Equity           DES         <GO>
```

- **Security first, then the action.** The user names the thing, and the
  function acts on the "loaded" security. If no security is typed, the
  function uses the one already loaded, so security context carries from
  screen to screen.
- **Short mnemonics** (2–5 letters) name functions. Experts type them; novices
  find them through autocomplete and search.
- **The ticker identifies by market:** `<ticker> <exchange/country> <sector>`,
  e.g. `VOD LN Equity` or `EURUSD Curncy`. The sector suffix removes ambiguity
  across asset classes.
- **Autocomplete everywhere.** Typing free text into the command line searches
  securities, functions, people and news at once.

### 2.2 Dedicated keyboard
- **Market-sector keys** (one key per asset class: Govt, Corp, Mtge, M-Mkt,
  Muni, Pfd, Equity, Cmdty, Index, Curncy) put the sector suffix into the
  command.
- **GO** runs the command. **CANCEL** clears it or backs out. **MENU** goes up
  one level. **PAGE FWD/BACK** moves through pages. **HELP** opens context help,
  and pressing it twice reaches a live help desk.
- On a standard keyboard these map to F-keys, Enter, Esc and so on. *Lesson:* a
  small, fixed set of verbs that work the same on every screen.

### 2.3 Screen conventions
- **High density, low chrome.** Dark background, monospace-aligned numbers,
  color reserved for meaning (up/down, editable fields, warnings).
- **Numbered actions.** Menu items and fields carry numbers. Typing the number
  and GO triggers the item, so the user never leaves the keyboard.
- **Editable fields are visually distinct** and reachable with Tab.
- **Multiple independent panels** (historically four), each with its own
  command line and loaded security. A launcher/workspace saves layouts,
  monitors and charts.
- **Linking.** Panels and monitors can be linked so that changing the security
  in one updates the others.

### 2.4 Discoverability
- Searching for a function by keyword ("price graph", "dividends") returns
  ranked functions.
- Every screen has HELP. Context menus on any number show "what is this field /
  where does it come from."
- Grab/export: send any screen to email, Excel or the clipboard.

## 3. Function taxonomy (publicly documented examples)

These are grouped by job to be done. finops-terminal should define **its own**
command names; the right-hand column describes the capability only.

| Job | Representative public functions | Capability |
|---|---|---|
| Describe a security | DES, CF, RELS | Overview, filings, related securities |
| Price & chart | GP, GIP, HP, GPO | Historical line/OHLC charts, intraday, price tables |
| Quotes & depth | QR, ALLQ, MBO/MBP | Time & sales, all dealer quotes, order book |
| Market overview | WEI, WB, WCRS, MOST, TOP | World indices, bonds, FX, most active, top news |
| News | N, CN, TOP, NI | News feeds, company news, topic filters |
| Fundamentals | FA, EE, ANR, ERN, DVD | Financial statements, estimates, analyst ratings, earnings, dividends |
| Corporate events | EVTS, CACS | Earnings dates, conferences, corporate actions |
| Ownership & supply chain | HDS, SPLC | Holders, suppliers/customers |
| Screening | EQS, SRCH | Equity/bond screeners on any field |
| Economics | ECO, WECO, ECST | Economic calendar, world economic data, statistics |
| Fixed income | YAS, CRVF, GC, BTMM, WIRP | Yield/spread analysis, curves, money markets, rate expectations |
| FX & derivatives | FXC, OMON, OVME, SWPM | Cross rates, option monitor, option/swap pricing |
| Portfolio & risk | PORT, MARS | Holdings, attribution, risk and scenario analysis |
| Communication | IB, MSG | Chat, messaging |
| Workspace | Launchpad, monitors, alerts | Saved layouts, watchlists, alert rules |
| Data query | BQL, Excel add-in, BLPAPI | Programmatic access to the same data |

**Patterns that recur across functions:**
1. A header showing the loaded security, last price and change.
2. A parameter strip (date range, currency, period, comparison securities).
3. One primary visualization (table or chart) with numbered sub-tabs.
4. An export/alert/help action set.

## 4. The open API — BLPAPI

Bloomberg publishes BLPAPI: SDKs for C/C++, Java, .NET and Python, with public
documentation and examples on GitHub. The SDK source is under a permissive
license, but **using it needs a Bloomberg entitlement** (a Terminal on
localhost, Server API or B-PIPE). Its *design* is a good public model for
finops-terminal's data layer.

### 4.1 Core abstractions
| Concept | Role |
|---|---|
| `Session` / `SessionOptions` | One connection to a data source (host, port, auth). Async (event queue) or sync. |
| `Service` | A named capability opened on a session, e.g. `//blp/refdata`. Each service exposes a schema. |
| `Request` | A typed operation on a service (`HistoricalDataRequest`, …). It is filled in through schema-checked elements. |
| `Subscription` | A streaming topic: security + fields + options (interval, delayed). |
| `Event` / `Message` | Everything arrives as events: `PARTIAL_RESPONSE` and `RESPONSE` for requests, `SUBSCRIPTION_DATA` and `SUBSCRIPTION_STATUS` for streams, `SESSION_STATUS` and `SERVICE_STATUS` for lifecycle. |
| `CorrelationId` | Ties every message to the request or subscription that caused it. |
| `Identity` / authorization | Per-user entitlements, so data is only shown to users entitled to it. |

### 4.2 Main services
| Service | Paradigm | Operations / content |
|---|---|---|
| `//blp/refdata` | request/response | `ReferenceDataRequest` (current field values, supports overrides), `HistoricalDataRequest` (daily/weekly/… series), `IntradayBarRequest`, `IntradayTickRequest` |
| `//blp/mktdata` | subscription | Real-time fields (`LAST_PRICE`, `BID`, `ASK`, `VOLUME`…), with optional conflation interval |
| `//blp/mktbar` | subscription | Streaming OHLC bars |
| `//blp/apiflds` | request/response | Field search and metadata (field mnemonic, type, description) |
| `//blp/instruments` | request/response | Security lookup: instrument, curve and government lookups |
| `//blp/pagedata` | subscription | Legacy page monitors |
| `//blp/emapisvc` | request/response | EMSX order management |

### 4.3 Design ideas worth reusing
1. **Fields as a data dictionary.** Every datum is `security × field (× date)`.
   Fields have stable mnemonics, types and documentation that can be searched
   (`apiflds`). This makes screens, screeners, Excel and the API all share one
   vocabulary.
2. **Overrides.** Requests take field overrides (e.g. a different currency or
   period) instead of needing new endpoints.
3. **Partial responses.** Large requests stream back in chunks, so the UI can
   render progressively.
4. **One event loop for requests and streams,** with correlation IDs. The
   client code has one dispatch path.
5. **Entitlements live in the data layer,** not in the UI.
6. **Status as data.** Session and service health are events the UI can show.

## 5. Takeaways for finops-terminal

**Build on:**
- A keyboard-first command line: noun first, then verb, with context carried
  between screens.
- A small set of global verbs (go, back, up, page, help) that behave the same
  on every screen.
- Multi-panel workspaces with security-linked panels and saved layouts.
- A single field dictionary shared by screens, screeners, exports and a public
  query API.
- A data layer modeled on request/response plus subscription with correlation
  IDs, partial responses and per-user entitlements.
- Dense, numeric-first, accessible visual design, with color reserved for
  meaning.

**Do differently or avoid:**
- Our own command vocabulary, visual identity and naming. Don't reuse
  Bloomberg mnemonics as primary commands, and don't use "Bloomberg" in product
  naming or UI.
- Discoverability as a first-class feature (command palette and fuzzy search
  from day one) rather than relying on memorized mnemonics.
- Know each data source's terms. Free and commercial APIs each have their own
  redistribution terms; the provider layer must record those terms and enforce
  them (see ARCHITECTURE.md §4.1 for the chosen sources).
- No chat network at launch: it's the hardest feature to bootstrap and not
  needed to be useful.

## Sources
- BLPAPI Developer's Guide (public copies; check against current Bloomberg docs):
  [usermanual.wiki mirror](https://usermanual.wiki/Document/blpapidevelopersguide.2127255432/html)
- BLPAPI service overview: [API Evangelist — BLPAPI Core](https://apis.apievangelist.com/store/bloomberg-blpapi-core/)
- Request usage through a third-party wrapper: [BLPData.jl API reference](https://docs.juliahub.com/General/BLPData/stable/api/)
- Integration listing request types: [interop.io Bloomberg adapter](https://docs.interop.io/adapters/bloomberg/market-data/overview/index.html)
- Bloomberg API library and SDK: https://www.bloomberg.com/professional/support/api-library/
