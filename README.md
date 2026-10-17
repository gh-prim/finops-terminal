# finops-terminal

A native macOS market terminal (SwiftUI) with a local Python data gateway.

- `app/` — SwiftUI app (Swift package): 1/2/4 linked panels, search, watchlists, and 17
  functions (QUOTE CHART DESC NEWS FIN EST EVT HOLD FILE OPT MKT MOVERS SCRN ECON CURVE PORT ALERT).
  Everything works by clicking or by typing commands — see HELP in the app.
- `gateway/` — Python sidecar (FastAPI + yfinance), started automatically by the app.
- `docs/` — [architecture](docs/ARCHITECTURE.md) and the [clean-room study](docs/research/bloomberg-terminal-study.md).

## Requirements
macOS 15+, Xcode 16+ (Swift 6), and [uv](https://docs.astral.sh/uv/). uv installs Python 3.12
and the gateway's dependencies on first launch.

## Setup
Open **Settings (⌘,)** in the app:
- **FRED API key** (free, [get one here](https://fred.stlouisfed.org/docs/api/api_key.html)) — needed for ECON and CURVE.
- **EDGAR contact email** — SEC asks automated clients to identify themselves (used for FIN and FILE).

## Run
```bash
cd app && ./scripts/make-app.sh && open build/finops-terminal.app
```
Or open `app/Package.swift` in Xcode and run the `FinopsTerminal` scheme.

Gateway logs: `~/Library/Application Support/finops-terminal/gateway.log`.

## Test
```bash
cd gateway && uv run pytest
cd app && swift test
```

Market data comes from Yahoo Finance through the unofficial `yfinance` library.
It is for personal use only and may be delayed.
