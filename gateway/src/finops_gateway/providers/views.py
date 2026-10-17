"""Visual and analytical screens: HEAT, FXM, PERF, GRID, CORR, RV, RELS, DCF, PORT analytics, WB, CB, SENT.

All functions are blocking and return documents (see documents.py).
"""

from __future__ import annotations

import datetime as dt
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import pandas as pd
import yfinance as yf

from .. import analytics as qa
from .. import securities
from ..cache import ttl_cache
from ..documents import (bars, choices, column, document, donut, graph, kv, matrix, row, scatter, series,
                         sparkgrid, table, text, treemap)
from . import edgar, fred
from .http import get_json
from .yahoo import _retry_locked
from .yahoo_research import SOURCE, news

# MARK: Helpers


@_retry_locked
def closes(symbols: tuple[str, ...], period: str = "1y", interval: str = "1d") -> pd.DataFrame:
    """Close prices, one column per symbol (missing symbols dropped)."""
    data = yf.download(list(symbols), period=period, interval=interval, group_by="ticker", progress=False,
                       auto_adjust=True, threads=True)
    frame = {}
    for s in symbols:
        try:
            col = data[s]["Close"] if len(symbols) > 1 else data["Close"]
            if isinstance(col, pd.DataFrame):
                col = col.iloc[:, 0]
            col = col.dropna()
            if len(col) > 1:
                frame[s] = col
        except KeyError:
            continue
    return pd.DataFrame(frame)


_cached_closes = ttl_cache(300, maxsize=64)(closes)


def period_return(c: pd.Series, days: int | None = None, ytd: bool = False) -> float | None:
    c = c.dropna()
    if len(c) < 2:
        return None
    if ytd:
        start = c[c.index >= pd.Timestamp(dt.date.today().year, 1, 1, tz=c.index.tz)]
        base = c[c.index < start.index[0]].iloc[-1] if len(start) and (c.index < start.index[0]).any() else c.iloc[0]
    else:
        base = c.iloc[-(days + 1)] if days is not None and len(c) > days else c.iloc[0]
    return (float(c.iloc[-1]) / float(base) - 1) * 100


def resolve_list(raw: str) -> list[tuple[str, str]]:
    """'AAPL US EQ;MSFT;^GSPC' -> [(typed, yahoo symbol)] (invalid entries skipped)."""
    out = []
    for item in [s.strip() for s in raw.replace(",", ";").split(";") if s.strip()]:
        try:
            out.append((item.upper(), securities.resolve(item).symbol))
        except ValueError:
            continue
    return out


@ttl_cache(3600, maxsize=512)
@_retry_locked
def info(symbol: str) -> dict[str, Any]:
    try:
        return yf.Ticker(symbol).get_info() or {}
    except Exception:
        return {}


def infos(symbols: list[str]) -> dict[str, dict[str, Any]]:
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(zip(symbols, pool.map(info, symbols)))


# MARK: HEAT — sector / company treemap (IMAP-like)

SECTORS = {
    "TECHNOLOGY": "technology", "FINANCIAL": "financial-services", "HEALTHCARE": "healthcare",
    "CONSUMER-CYCLICAL": "consumer-cyclical", "COMMUNICATION": "communication-services", "INDUSTRIALS": "industrials",
    "CONSUMER-DEFENSIVE": "consumer-defensive", "ENERGY": "energy", "MATERIALS": "basic-materials",
    "REAL-ESTATE": "real-estate", "UTILITIES": "utilities",
}
PERIODS = {"1D": 1, "1W": 5, "1M": 21, "3M": 63, "YTD": None, "1Y": 252}


@ttl_cache(3600)
@_retry_locked
def _sector(key: str) -> tuple[str, float, pd.DataFrame]:
    s = yf.Sector(key)
    return s.name, float((s.overview or {}).get("market_weight") or 0), s.top_companies


def heatmap(sector: str | None, period: str) -> dict[str, Any]:
    period = period if period in PERIODS else "1D"
    keys = [SECTORS[sector]] if sector in SECTORS else list(SECTORS.values())
    per_sector = 40 if sector in SECTORS else 12
    with ThreadPoolExecutor(max_workers=6) as pool:
        sectors = list(pool.map(_sector, keys))
    universe = tuple(sorted({sym for _, _, top in sectors for sym in list(top.index[:per_sector])}))
    prices = _cached_closes(universe, "1y")
    groups = []
    for name, weight, top in sectors:
        items = []
        for sym, r in top.head(per_sector).iterrows():
            if sym not in prices:
                continue
            ret = period_return(prices[sym], PERIODS[period], ytd=period == "YTD")
            items.append({"label": sym, "detail": r["name"], "weight": float(r["market weight"]) * (weight or 1),
                          "value": ret, "cmd": f"{sym} CHART"})
        if items:
            groups.append({"label": name, "items": items})
    return document("Market heatmap", [
        choices("period", "Period", [(p, f"HEAT {p}" + (f" {sector}" if sector in SECTORS else "")) for p in PERIODS], period),
        choices("sector", "Sector", [("All", f"HEAT {period}")] + [(k.title().replace("-", " "), f"HEAT {period} {k}")
                                                                   for k in SECTORS], sector.title() if sector else "All"),
        treemap("heat", f"Largest US companies · area = market weight · colour = {period} change", groups),
    ], SOURCE, notes=["Click a tile to open its chart."])


# MARK: FXM — currency cross-rate matrix

CURRENCIES = ["USD", "EUR", "JPY", "GBP", "CHF", "CAD", "AUD", "CNY"]


@ttl_cache(120)
def fx_matrix() -> dict[str, Any]:
    pairs = tuple(f"{c}=X" for c in CURRENCIES if c != "USD")  # USD→ccy
    prices = closes(pairs, "5d")
    last = {"USD": 1.0, **{c: float(prices[f"{c}=X"].iloc[-1]) for c in CURRENCIES if f"{c}=X" in prices}}
    prev = {"USD": 1.0, **{c: float(prices[f"{c}=X"].iloc[-2]) for c in CURRENCIES if f"{c}=X" in prices}}
    ccys = [c for c in CURRENCIES if c in last]
    # Cell (row A, col B) = price of 1 A in B.
    rates = [[None if a == b else last[b] / last[a] for b in ccys] for a in ccys]
    moves = [[None if a == b else ((last[b] / last[a]) / (prev[b] / prev[a]) - 1) * 100 for b in ccys] for a in ccys]
    return document("Currency matrix", [
        matrix("rates", "1 unit of row currency in column currency", ccys, ccys, rates, kind="price", scale="none"),
        matrix("moves", "1-day change % (green = row currency stronger)", ccys, ccys, moves, kind="pctchange"),
    ], SOURCE)


# MARK: PERF / GRID / CORR — watchlist analytics


def perf(raw: str) -> dict[str, Any]:
    items = resolve_list(raw)
    if not items:
        raise ValueError("no valid securities")
    prices = _cached_closes(tuple(sym for _, sym in items), "2y")
    rows, labels, cmds, vols = [], [], [], []
    for typed, sym in items:
        if sym not in prices:
            continue
        c = prices[sym]
        rows.append([period_return(c, PERIODS[p], ytd=p == "YTD") for p in PERIODS])
        vols.append({"label": typed, "value": qa.volatility(qa.returns(c.tail(63))) * 100, "cmd": f"{typed} CHART"})
        labels.append(typed)
        cmds.append(f"{typed} CHART")
    return document("Performance", [
        matrix("perf", "Total return % (dividends included)", labels, list(PERIODS), rows, kind="pctchange", row_cmds=cmds),
        bars("vol", "3-month annualised volatility", sorted(vols, key=lambda v: -v["value"]), kind="percent"),
    ], SOURCE, notes=["Click a row to open its chart."])


def grid(raw: str, range_code: str) -> dict[str, Any]:
    items = resolve_list(raw)
    period, interval = {"1M": ("1mo", "1d"), "3M": ("3mo", "1d"), "1Y": ("1y", "1d"), "5D": ("5d", "30m")}.get(range_code, ("3mo", "1d"))
    prices = _cached_closes(tuple(sym for _, sym in items), period, interval)
    cells = []
    for typed, sym in items:
        if sym in prices:
            c = prices[sym].dropna()
            cells.append({"label": typed, "detail": f"{float(c.iloc[-1]):,.2f}", "change": (float(c.iloc[-1]) / float(c.iloc[0]) - 1) * 100,
                          "points": [float(v) for v in c], "cmd": f"{typed} CHART"})
    return document("Chart grid", [
        choices("range", "Range", [(r, f"GRID {r}") for r in ("5D", "1M", "3M", "1Y")], range_code),
        sparkgrid("grid", None, cells),
    ], SOURCE)


def correlation(raw: str, range_code: str) -> dict[str, Any]:
    items = resolve_list(raw)
    period = {"3M": "3mo", "6M": "6mo", "1Y": "1y", "2Y": "2y", "5Y": "5y"}.get(range_code, "1y")
    prices = _cached_closes(tuple(sym for _, sym in items), period)
    labels = [t for t, s in items if s in prices]
    r = qa.returns(prices[[s for _, s in items if s in prices]])
    corr = r.corr().values.tolist()
    return document("Correlation", [
        choices("range", "Range", [(x, f"CORR {x}") for x in ("3M", "6M", "1Y", "2Y", "5Y")], range_code),
        matrix("corr", f"Correlation of daily returns · {range_code}", labels, labels, corr, kind="number", scale="correlation"),
    ], SOURCE)


# MARK: RV — relative valuation scatter vs industry peers

RV_METRICS = {
    "PE": ("P/E (ttm)", "trailingPE", 1, "number"),
    "FPE": ("P/E (forward)", "forwardPE", 1, "number"),
    "EVEBITDA": ("EV / EBITDA", "enterpriseToEbitda", 1, "number"),
    "PS": ("Price / sales", "priceToSalesTrailing12Months", 1, "number"),
    "PB": ("Price / book", "priceToBook", 1, "number"),
    "GROWTH": ("Revenue growth %", "revenueGrowth", 100, "percent"),
    "MARGIN": ("Net margin %", "profitMargins", 100, "percent"),
    "ROE": ("ROE %", "returnOnEquity", 100, "percent"),
    "RET1Y": ("52-week return %", "52WeekChange", 100, "pctchange"),
}


@ttl_cache(3600, maxsize=128)
@_retry_locked
def peers(symbol: str, limit: int = 15) -> list[str]:
    key = info(symbol).get("industryKey")
    if not key:
        return []
    top = yf.Industry(key).top_companies
    return [s for s in list(top.index) if s != symbol][:limit] if top is not None else []


def relative_value(symbol: str, x: str, y: str) -> dict[str, Any]:
    x = x if x in RV_METRICS else "FPE"
    y = y if y in RV_METRICS else "GROWTH"
    universe = [symbol, *peers(symbol)]
    data = infos(universe)

    def metric(sym: str, key: str) -> float | None:
        _, field, mult, _ = RV_METRICS[key]
        v = data[sym].get(field)
        return float(v) * mult if isinstance(v, int | float) else None

    points = [{"label": s, "x": metric(s, x), "y": metric(s, y), "size": data[s].get("marketCap"),
               "highlight": s == symbol, "cmd": f"{s} RV {x} {y}"} for s in universe]
    cols = ["PE", "FPE", "EVEBITDA", "GROWTH", "MARGIN", "RET1Y"]
    rows = [row([s, data[s].get("shortName"), data[s].get("marketCap"), *[metric(s, k) for k in cols]], cmd=f"{s} DESC")
            for s in universe]
    industry = data[symbol].get("industry") or "industry"
    return document(f"Relative value — {symbol} vs {industry}", [
        choices("x", "X axis", [(RV_METRICS[k][0], f"RV {k} {y}") for k in RV_METRICS], RV_METRICS[x][0]),
        choices("y", "Y axis", [(RV_METRICS[k][0], f"RV {x} {k}") for k in RV_METRICS], RV_METRICS[y][0]),
        scatter("rv", "Bubble size = market cap", RV_METRICS[x][0], RV_METRICS[y][0], points,
                x_kind=RV_METRICS[x][3], y_kind=RV_METRICS[y][3]),
        table("peers", "Peers", [column("sym", "Symbol"), column("name", "Name"), column("mcap", "Mkt cap", "compact"),
                                 *[column(k, RV_METRICS[k][0], RV_METRICS[k][3]) for k in cols]], rows),
    ], SOURCE, subtitle=symbol, notes=["Peers = largest companies in the same Yahoo industry."])


# MARK: RELS — relationship graph (SPLC-like, with the data that is public)


def relationships(symbol: str) -> dict[str, Any]:
    t = yf.Ticker(symbol)
    me = info(symbol)
    peer_syms = peers(symbol, 12)
    prices = _cached_closes(tuple([symbol, *peer_syms]), "1mo") if peer_syms else pd.DataFrame()
    peer_syms = [s for s in peer_syms if s in prices][:10]  # drop delisted / no-data symbols
    peer_info = infos(peer_syms)
    peer_nodes = [{"label": s, "detail": (peer_info[s].get("shortName") or "")[:22],
                   "value": period_return(prices[s], 1) if s in prices else None, "cmd": f"{s} RELS"} for s in peer_syms]

    def holder_nodes(df: pd.DataFrame | None) -> list[dict[str, Any]]:
        if not isinstance(df, pd.DataFrame) or df.empty:
            return []
        return [{"label": str(r.get("Holder"))[:26], "detail": f"{(r.get('pctHeld') or 0) * 100:.2f}% held",
                 "value": (r.get("pctChange") or 0) * 100} for _, r in df.head(10).iterrows()]

    center = {"label": me.get("shortName") or symbol, "detail": f"{symbol} · {me.get('industry', '')}",
              "lines": [f"Mkt cap {me.get('marketCap', 0) / 1e9:,.0f} B", f"Sector {me.get('sector', '—')}",
                        f"Employees {me.get('fullTimeEmployees', 0):,}"]}
    return document(f"Relationships — {symbol}", [
        graph("rels", None, center, [
            {"title": f"{len(peer_nodes)} industry peers · 1D %", "side": "left", "nodes": peer_nodes},
            {"title": "Top institutional holders · position change %", "side": "right", "nodes": holder_nodes(t.institutional_holders)},
            {"title": "Top funds", "side": "bottom", "nodes": holder_nodes(t.mutualfund_holders)[:8]},
        ]),
    ], SOURCE, subtitle=symbol, notes=[
        "Supplier and customer exposures (as in Bloomberg SPLC) are proprietary and not available from free sources; "
        "this graph shows the public relationships: industry peers and ownership.",
    ])


# MARK: DCF — discounted cash flow from SEC filings


def dcf(symbol: str, wacc: float | None, growth: float | None, terminal: float | None) -> dict[str, Any]:
    cik, name = edgar.cik_for(symbol)
    gaap = edgar._facts(cik).get("facts", {}).get("us-gaap", {})

    def annual(tags: list[str], flow: bool = True) -> dict[dt.date, float]:
        return edgar._series(gaap, tags, flow, False)

    ocf = annual(["NetCashProvidedByUsedInOperatingActivities"])
    capex = annual(["PaymentsToAcquirePropertyPlantAndEquipment"])
    years = sorted(ocf)[-6:]
    fcf_hist = [(y, ocf[y] - capex.get(y, 0.0)) for y in years]
    if not fcf_hist or fcf_hist[-1][1] <= 0:
        raise LookupError(f"{name} has no positive free cash flow to discount")
    base = fcf_hist[-1][1]
    if growth is None:  # default: historical FCF CAGR, clamped to a sane range
        first = next((v for _, v in fcf_hist if v > 0), base)
        n = max(len(fcf_hist) - 1, 1)
        growth = min(max((base / first) ** (1 / n) - 1, 0.0), 0.20)
    wacc = 0.09 if wacc is None else wacc
    terminal = 0.025 if terminal is None else terminal

    def latest(tags: list[str]) -> float:
        s = edgar._series(gaap, tags, False, True)
        return s[max(s)] if s else 0.0

    cash = latest(["CashAndCashEquivalentsAtCarryingValue"]) + latest(["MarketableSecuritiesCurrent", "ShortTermInvestments"])
    debt = latest(["LongTermDebtNoncurrent", "LongTermDebt"]) + latest(["LongTermDebtCurrent", "DebtCurrent"])
    shares_s = annual(["WeightedAverageNumberOfDilutedSharesOutstanding"])
    shares = shares_s[max(shares_s)] if shares_s else float(info(symbol).get("sharesOutstanding") or 0)
    price = float(info(symbol).get("currentPrice") or info(symbol).get("regularMarketPrice") or 0)

    def per_share(w: float, g: float, tg: float) -> float | None:
        try:
            ev, _ = qa.dcf(base, g, w, tg)
        except ValueError:
            return None
        return (ev + cash - debt) / shares if shares else None

    ev, flows = qa.dcf(base, growth, wacc, terminal)
    value = per_share(wacc, growth, terminal)
    waccs = [0.07, 0.08, 0.09, 0.10, 0.11]
    tgs = [0.015, 0.02, 0.025, 0.03, 0.035]
    args = lambda w, g, t: f"DCF W{w * 100:g} G{g * 100:g} T{t * 100:g}"  # noqa: E731
    last_year = fcf_hist[-1][0].year
    return document(f"DCF — {name}", [
        choices("wacc", "WACC", [(f"{w * 100:g}%", args(w, growth, terminal)) for w in waccs], f"{wacc * 100:g}%"),
        choices("growth", "FCF growth (5y)", [(f"{g}%", args(wacc, g / 100, terminal)) for g in (0, 5, 10, 15, 20)],
                f"{growth * 100:g}%"),
        choices("terminal", "Terminal growth", [(f"{t * 100:g}%", args(wacc, growth, t)) for t in tgs], f"{terminal * 100:g}%"),
        kv("Valuation", [
            ("Intrinsic value / share", value, "price"),
            ("Price", price, "price"),
            ("Upside", (value / price - 1) * 100 if value and price else None, "pctchange"),
            ("Enterprise value", ev, "compact"),
            ("+ cash & ST investments", cash, "compact"),
            ("− debt", debt, "compact"),
            ("Diluted shares", shares, "compact"),
        ]),
        kv("Assumptions", [
            ("Base FCF (FY%d)" % last_year, base, "compact"),
            ("FCF growth, 5 years", growth * 100, "percent"),
            ("WACC", wacc * 100, "percent"),
            ("Terminal growth", terminal * 100, "percent"),
        ]),
        series("fcf", "Free cash flow: reported and projected", [
            {"label": "Reported", "points": [(dt.datetime(y.year, y.month, y.day).timestamp(), v) for y, v in fcf_hist]},
            {"label": "Projected", "points": [(dt.datetime(last_year + i, 12, 31).timestamp(), v)
                                              for i, v in enumerate([base, *flows])]},
        ], kind="compact"),
        matrix("sensitivity", "Value per share · rows WACC, columns terminal growth (green = above price)",
               [f"{w * 100:g}%" for w in waccs], [f"{t * 100:g}%" for t in tgs],
               [[per_share(w, growth, t) for t in tgs] for w in waccs], kind="price", center=price),
    ], "SEC EDGAR (cash flows, balance sheet) + Yahoo price", subtitle=symbol, notes=[
        "Two-stage DCF on free cash flow (operating cash flow − capex). A model, not advice: small changes in WACC or growth move the result a lot.",
    ])


# MARK: PORT analytics


def portfolio(positions: str) -> dict[str, Any]:
    holdings = []
    for part in [p for p in positions.split(";") if "|" in p]:
        typed, qty = part.rsplit("|", 1)
        try:
            holdings.append((typed.strip().upper(), securities.resolve(typed).symbol, float(qty)))
        except ValueError:
            continue
    if not holdings:
        raise ValueError("no positions")
    symbols = tuple(sorted({s for _, s, _ in holdings} | {"^GSPC", "^IRX"}))
    prices = _cached_closes(symbols, "1y").ffill()
    value = sum(prices[s] * q for _, s, q in holdings if s in prices).dropna()
    r = qa.returns(value)
    market = qa.returns(prices["^GSPC"]) if "^GSPC" in prices else None
    rf = float(prices["^IRX"].iloc[-1]) / 100 if "^IRX" in prices else 0.0
    total = float(value.iloc[-1])
    var95, var99 = qa.historical_var(r, 0.95), qa.historical_var(r, 0.99)

    data = infos([s for _, s, _ in holdings])
    by_sector: dict[str, float] = {}
    for typed, s, q in holdings:
        if s in prices:
            sector = data[s].get("sector") or {"ETF": "ETFs", "INDEX": "Indices", "CRYPTOCURRENCY": "Crypto",
                                               "CURRENCY": "Currencies", "FUTURE": "Futures"}.get(data[s].get("quoteType", ""), "Other")
            by_sector[sector] = by_sector.get(sector, 0) + float(prices[s].iloc[-1]) * q
    labels = [t for t, s, _ in holdings if s in prices]
    corr = qa.returns(prices[[s for _, s, _ in holdings if s in prices]]).corr().values.tolist() if len(labels) > 1 else []

    blocks = [
        kv("Risk & return (1 year)", [
            ("Market value", total, "price"),
            ("Return (annualised)", qa.annualized_return(r) * 100, "pctchange"),
            ("Volatility", qa.volatility(r) * 100, "percent"),
            ("Sharpe ratio", qa.sharpe(r, rf), "number"),
            ("Beta vs S&P 500", qa.beta(r, market) if market is not None else None, "number"),
            ("Max drawdown", qa.max_drawdown(r) * 100, "pctchange"),
        ]),
        kv("Value at Risk (1 day, historical)", [
            ("VaR 95%", var95 * 100, "percent"), ("VaR 95% ($)", var95 * total, "price"),
            ("VaR 99%", var99 * 100, "percent"), ("VaR 99% ($)", var99 * total, "price"),
            ("Risk-free (13w T-bill)", rf * 100, "percent"),
        ]),
        donut("sectors", "Sector allocation", [{"label": k, "value": v / total * 100} for k, v in
                                               sorted(by_sector.items(), key=lambda kv: -kv[1])]),
        series("growth", "Growth of 100 · portfolio vs S&P 500", [
            {"label": "Portfolio", "points": [(t.timestamp(), v / float(value.iloc[0]) * 100) for t, v in value.items()]},
            *([{"label": "S&P 500", "points": [(t.timestamp(), v / float(prices['^GSPC'].dropna().iloc[0]) * 100)
                                              for t, v in prices["^GSPC"].dropna().items()]}] if "^GSPC" in prices else []),
        ]),
    ]
    if corr:
        blocks.append(matrix("corr", "Correlation of daily returns", labels, labels, corr, scale="correlation"))
    return document("Portfolio analytics", blocks, SOURCE, notes=[
        "Uses current quantities over the past year (no trade history). VaR is historical, not parametric.",
    ])


# MARK: WB — World Bank indicators

WB_INDICATORS = {
    "GDP": ("NY.GDP.MKTP.KD.ZG", "Real GDP growth, %", "pctchange"),
    "CPI": ("FP.CPI.TOTL.ZG", "Inflation, consumer prices, %", "percent"),
    "UNEMP": ("SL.UEM.TOTL.ZS", "Unemployment, % of labour force", "percent"),
    "DEBT": ("GC.DOD.TOTL.GD.ZS", "Central government debt, % of GDP", "percent"),
    "CA": ("BN.CAB.XOKA.GD.ZS", "Current account balance, % of GDP", "pctchange"),
    "GDPPC": ("NY.GDP.PCAP.CD", "GDP per capita, current US$", "compact"),
    "SIZE": ("NY.GDP.MKTP.CD", "GDP, current US$", "compact"),
}
WB_COUNTRIES = ["USA", "CHN", "JPN", "DEU", "IND", "GBR", "FRA", "ITA", "CAN", "BRA", "KOR", "AUS", "ESP", "MEX",
                "IDN", "NLD", "SAU", "TUR", "CHE", "ARG", "ZAF"]


@ttl_cache(86400, maxsize=32)
def world_bank(indicator: str) -> dict[str, Any]:
    indicator = indicator if indicator in WB_INDICATORS else "GDP"
    code, title, kind = WB_INDICATORS[indicator]
    year = dt.date.today().year
    raw = get_json(f"https://api.worldbank.org/v2/country/{';'.join(WB_COUNTRIES)}/indicator/{code}",
                   {"format": "json", "date": f"{year - 15}:{year}", "per_page": 2000})
    obs: dict[str, list[tuple[int, float]]] = {}
    names: dict[str, str] = {}
    for o in raw[1] if len(raw) > 1 and raw[1] else []:
        if o["value"] is None:
            continue
        iso = o["countryiso3code"]
        names[iso] = o["country"]["value"]
        obs.setdefault(iso, []).append((int(o["date"]), float(o["value"])))
    latest = {iso: sorted(v)[-1] for iso, v in obs.items()}
    order = sorted(latest, key=lambda iso: -latest[iso][1])
    big5 = [c for c in ["USA", "CHN", "DEU", "JPN", "IND", "FRA"] if c in obs]
    rows = [row([names[i], latest[i][0], latest[i][1], (sorted(obs[i])[-2][1] if len(obs[i]) > 1 else None)]) for i in order]
    return document(f"World Bank — {title}", [
        choices("indicator", "Indicator", [(WB_INDICATORS[k][1].split(",")[0], f"WB {k}") for k in WB_INDICATORS], title.split(",")[0]),
        bars("latest", f"{title} · latest available year", [{"label": names[i], "value": latest[i][1]} for i in order], kind=kind),
        series("history", "History · largest economies", [
            {"label": names[i], "points": [(dt.datetime(y, 12, 31).timestamp(), v) for y, v in sorted(obs[i])]} for i in big5
        ], kind=kind),
        table("data", None, [column("country", "Country"), column("year", "Year", "text"), column("latest", "Latest", kind),
                             column("prev", "Previous", kind)], rows),
    ], "World Bank Open Data (annual)", notes=["Annual data; the latest year differs by country."])


# MARK: CB — central bank policy rates (FRED)

CENTRAL_BANKS = [
    ("Federal Reserve", "FEDFUNDS"), ("European Central Bank", "ECBDFR"), ("Bank of England", "IRSTCB01GBM156N"),
    ("Bank of Japan", "IRSTCB01JPM156N"), ("Swiss National Bank", "IRSTCB01CHM156N"), ("Bank of Canada", "IRSTCB01CAM156N"),
    ("Reserve Bank of Australia", "IRSTCB01AUM156N"), ("People's Bank of China", "IRSTCB01CNM156N"),
]


@ttl_cache(3600)
def central_banks() -> dict[str, Any]:
    def latest(item: tuple[str, str]) -> dict[str, Any] | None:
        name, sid = item
        try:
            obs = fred._observations(sid, limit=13, desc=True)
        except fred.MissingKey:
            raise
        except Exception:
            return None
        if not obs:
            return None
        year_ago = obs[12][1] if len(obs) > 12 else obs[-1][1]
        return row([name, obs[0][1], obs[1][1] if len(obs) > 1 else None, obs[0][1] - year_ago, obs[0][0], sid],
                   cmd=f"ECON {sid}")

    with ThreadPoolExecutor(max_workers=4) as pool:
        rows = [r for r in pool.map(latest, CENTRAL_BANKS) if r]
    return document("Central banks", [
        bars("rates", "Policy rate, %", [{"label": r["cells"][0], "value": r["cells"][1], "cmd": r["cmd"]} for r in rows],
             kind="percent"),
        table("banks", None, [column("bank", "Central bank"), column("rate", "Rate", "percent"),
                              column("prev", "Previous", "percent"), column("chg", "Change 1Y", "change"),
                              column("date", "As of", "date"), column("id", "Series")], rows),
    ], fred.SOURCE, notes=["Click a bank for its rate history. Monthly OECD series for most banks; daily for the ECB."])


# MARK: SENT — headline sentiment


def sentiment(symbol: str) -> dict[str, Any]:
    doc = news(symbol)
    rows = doc["blocks"][0]["rows"] if doc["blocks"] else []
    scored = [(r, qa.headline_sentiment(r["cells"][1] or "")) for r in rows]
    if not scored:
        raise LookupError(f"no headlines for {symbol}")
    pos = sum(s > 0 for _, s in scored)
    neg = sum(s < 0 for _, s in scored)
    avg = sum(s for _, s in scored) / len(scored)
    return document(f"Headline sentiment — {symbol}", [
        kv("Summary", [("Score (−1…+1)", avg, "number"), ("Headlines", len(scored), "int"),
                       ("Positive", pos / len(scored) * 100, "percent"), ("Negative", neg / len(scored) * 100, "percent")]),
        bars("scores", "Score per headline", [{"label": (r["cells"][1] or "")[:60], "value": s, "cmd": None}
                                              for r, s in scored], kind="number"),
        table("headlines", None, [column("time", "Time", "datetime"), column("score", "Score", "change"),
                                  column("title", "Headline"), column("source", "Source")],
              [{**row([r["cells"][0], s, r["cells"][1], r["cells"][2]]), "url": r.get("url")} for r, s in scored]),
    ], "Yahoo Finance headlines · finance word lexicon (Loughran–McDonald style)", subtitle=symbol, notes=[
        "Lexicon scoring of headlines only. Reddit needs API credentials, X a paid API, and Polymarket is blocked in France, "
        "so they aren't included.",
    ])
