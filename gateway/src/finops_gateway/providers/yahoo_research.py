"""Yahoo Finance research screens (DESC, NEWS, EST, EVT, HOLD, OPT, MKT, MOVERS, SCRN).

Every function is blocking and returns a document (see documents.py).
"""

from __future__ import annotations

import datetime as dt
import re
from typing import Any

import pandas as pd
import yfinance as yf

from ..cache import ttl_cache
from ..documents import cell, choices, column, document, kv, row, series, table, text
from .yahoo import _retry_locked

SOURCE = "Yahoo Finance via yfinance (unofficial, may be delayed)"


def _pct(value: Any) -> float | None:
    """Yahoo ratios (0.123) -> percent (12.3)."""
    v = cell(value)
    return v * 100 if isinstance(v, int | float) else None


# MARK: DESC


@ttl_cache(3600)
@_retry_locked
def profile(symbol: str) -> dict[str, Any]:
    info = yf.Ticker(symbol).get_info()
    if not info or not (info.get("longName") or info.get("shortName")):
        raise LookupError(f"no profile for {symbol}")
    name = info.get("longName") or info.get("shortName")
    location = ", ".join(x for x in (info.get("city"), info.get("state"), info.get("country")) if x)
    website = info.get("website")
    blocks = [
        kv("Company", [
            ("Name", name, "text"),
            ("Sector", info.get("sector"), "text"),
            ("Industry", info.get("industry"), "text"),
            ("Exchange", info.get("fullExchangeName") or info.get("exchange"), "text"),
            ("Currency", info.get("currency"), "text"),
            ("Location", location or None, "text"),
            ("Employees", info.get("fullTimeEmployees"), "int"),
            *([("Website", website, "text", website)] if website else []),
        ]),
        kv("Valuation", [
            ("Market cap", info.get("marketCap"), "compact"),
            ("Enterprise value", info.get("enterpriseValue"), "compact"),
            ("P/E (ttm)", info.get("trailingPE"), "number"),
            ("P/E (fwd)", info.get("forwardPE"), "number"),
            ("PEG", info.get("trailingPegRatio"), "number"),
            ("Price / book", info.get("priceToBook"), "number"),
            ("Price / sales", info.get("priceToSalesTrailing12Months"), "number"),
            ("EV / EBITDA", info.get("enterpriseToEbitda"), "number"),
        ]),
        kv("Trading", [
            ("52w high", info.get("fiftyTwoWeekHigh"), "price"),
            ("52w low", info.get("fiftyTwoWeekLow"), "price"),
            ("52w change", _pct(info.get("52WeekChange")), "pctchange"),
            ("Beta", info.get("beta"), "number"),
            ("Avg volume (3m)", info.get("averageVolume"), "compact"),
            ("Shares out", info.get("sharesOutstanding"), "compact"),
            ("Float", info.get("floatShares"), "compact"),
            ("Short % float", _pct(info.get("shortPercentOfFloat")), "percent"),
        ]),
        kv("Profitability", [
            ("Revenue (ttm)", info.get("totalRevenue"), "compact"),
            ("Revenue growth", _pct(info.get("revenueGrowth")), "pctchange"),
            ("Gross margin", _pct(info.get("grossMargins")), "percent"),
            ("Operating margin", _pct(info.get("operatingMargins")), "percent"),
            ("Net margin", _pct(info.get("profitMargins")), "percent"),
            ("ROE", _pct(info.get("returnOnEquity")), "percent"),
            ("Free cash flow", info.get("freeCashflow"), "compact"),
            ("Total cash", info.get("totalCash"), "compact"),
            ("Total debt", info.get("totalDebt"), "compact"),
        ]),
        kv("Dividend", [
            ("Rate", info.get("dividendRate"), "price"),
            ("Yield", info.get("dividendYield"), "percent"),  # already in % on Yahoo
            ("Payout ratio", _pct(info.get("payoutRatio")), "percent"),
            ("Ex-dividend", info.get("exDividendDate"), "date"),
        ]),
    ]
    if summary := info.get("longBusinessSummary"):
        blocks.insert(0, text("Business", summary))
    try:
        closes = yf.Ticker(symbol).history(period="5y", interval="1wk")["Close"].dropna()
        blocks.append(series("price", f"Price · 5 years ({info.get('currency') or ''})".replace(" ()", ""),
                             [{"label": symbol, "points": [(int(t.timestamp()), float(c)) for t, c in closes.items()]}],
                             kind="price"))
    except Exception:
        pass  # the profile stands on its own
    return document(name, blocks, SOURCE, subtitle=symbol)


# MARK: NEWS


@ttl_cache(300)
@_retry_locked
def news(query: str, count: int = 25) -> dict[str, Any]:
    items = yf.Search(query, max_results=1, news_count=count).news
    rows = [
        row([n.get("providerPublishTime"), n.get("title"), n.get("publisher")], url=n.get("link"))
        for n in items
        if n.get("title")
    ]
    return document(
        f"News — {query}",
        [table("news", None, [column("time", "Time", "datetime"), column("title", "Headline"),
                              column("source", "Source")], rows)],
        "Yahoo Finance search (headlines link to publishers)",
        notes=[] if rows else ["No headlines found."],
    )


# MARK: EST

PERIOD_LABELS = {"0q": "Current qtr", "+1q": "Next qtr", "0y": "Current year", "+1y": "Next year"}


@ttl_cache(3600)
@_retry_locked
def estimates(symbol: str) -> dict[str, Any]:
    t = yf.Ticker(symbol)
    blocks: list[dict[str, Any]] = []

    targets = t.analyst_price_targets or {}
    current, mean = targets.get("current"), targets.get("mean")
    blocks.append(kv("Price targets", [
        ("Current", current, "price"),
        ("Low", targets.get("low"), "price"),
        ("Mean", mean, "price"),
        ("Median", targets.get("median"), "price"),
        ("High", targets.get("high"), "price"),
        ("Upside to mean", (mean / current - 1) * 100 if mean and current else None, "pctchange"),
    ]))

    rec = t.recommendations_summary
    if isinstance(rec, pd.DataFrame) and not rec.empty:
        labels = {"0m": "Now", "-1m": "1 month ago", "-2m": "2 months ago", "-3m": "3 months ago"}
        blocks.append(table("ratings", "Analyst ratings", [
            column("period", "Period"), column("sb", "Strong buy", "int"), column("b", "Buy", "int"),
            column("h", "Hold", "int"), column("s", "Sell", "int"), column("ss", "Strong sell", "int"),
        ], [row([labels.get(r.period, r.period), r.strongBuy, r.buy, r.hold, r.sell, r.strongSell])
            for r in rec.itertuples()]))

    for attr, title, kind in (("earnings_estimate", "EPS estimates", "price"),
                              ("revenue_estimate", "Revenue estimates", "compact")):
        df = getattr(t, attr)
        if isinstance(df, pd.DataFrame) and not df.empty:
            blocks.append(table(attr, title, [
                column("period", "Period"), column("avg", "Average", kind), column("low", "Low", kind),
                column("high", "High", kind), column("ya", "Year ago", kind),
                column("n", "Analysts", "int"), column("g", "Growth", "pctchange"),
            ], [row([PERIOD_LABELS.get(p, p), r.get("avg"), r.get("low"), r.get("high"),
                     r.get("yearAgoEps", r.get("yearAgoRevenue")), r.get("numberOfAnalysts"), _pct(r.get("growth"))])
                for p, r in df.iterrows()]))

    ud = t.upgrades_downgrades
    if isinstance(ud, pd.DataFrame) and not ud.empty:
        ud = ud.head(25)
        blocks.append(table("changes", "Rating changes", [
            column("date", "Date", "date"), column("firm", "Firm"), column("to", "To"),
            column("from", "From"), column("action", "Action"),
        ], [row([idx, r.get("Firm"), r.get("ToGrade"), r.get("FromGrade"), r.get("Action")])
            for idx, r in ud.iterrows()]))

    return document(f"Estimates — {symbol}", blocks, SOURCE, subtitle=symbol)


# MARK: EVT / DIV


@ttl_cache(3600)
@_retry_locked
def events(symbol: str) -> dict[str, Any]:
    t = yf.Ticker(symbol)
    blocks: list[dict[str, Any]] = []
    cal = t.calendar or {}
    next_earnings = cal.get("Earnings Date") or []
    blocks.append(kv("Upcoming", [
        ("Next earnings", next_earnings[0] if next_earnings else None, "date"),
        ("EPS estimate", cal.get("Earnings Average"), "price"),
        ("EPS range", f"{cal['Earnings Low']} – {cal['Earnings High']}" if cal.get("Earnings Low") else None, "text"),
        ("Revenue estimate", cal.get("Revenue Average"), "compact"),
        ("Ex-dividend", cal.get("Ex-Dividend Date"), "date"),
        ("Dividend paid", cal.get("Dividend Date"), "date"),
    ]))

    ed = t.earnings_dates
    if isinstance(ed, pd.DataFrame) and not ed.empty:
        blocks.append(table("earnings", "Earnings history", [
            column("date", "Date", "date"), column("est", "EPS estimate", "price"),
            column("act", "Reported EPS", "price"), column("surprise", "Surprise", "pctchange"),
        ], [row([idx, r.get("EPS Estimate"), r.get("Reported EPS"), r.get("Surprise(%)")])
            for idx, r in ed.iterrows()]))

    div = t.dividends
    if isinstance(div, pd.Series) and not div.empty:
        recent = div.iloc[::-1].head(40)
        blocks.append(table("dividends", "Dividends", [column("date", "Ex-date", "date"),
                                                        column("amount", "Amount", "price")],
                            [row([idx, v]) for idx, v in recent.items()]))

    splits = t.splits
    if isinstance(splits, pd.Series) and not splits.empty:
        blocks.append(table("splits", "Splits", [column("date", "Date", "date"), column("ratio", "Ratio")],
                            [row([idx, f"{v:g}:1"]) for idx, v in splits.iloc[::-1].items()]))

    return document(f"Events — {symbol}", blocks, SOURCE, subtitle=symbol)


# MARK: HOLD


@ttl_cache(3600)
@_retry_locked
def holders(symbol: str) -> dict[str, Any]:
    t = yf.Ticker(symbol)
    blocks: list[dict[str, Any]] = []

    major = t.major_holders
    if isinstance(major, pd.DataFrame) and not major.empty:
        values = major["Value"].to_dict()
        blocks.append(kv("Ownership", [
            ("Insiders", _pct(values.get("insidersPercentHeld")), "percent"),
            ("Institutions", _pct(values.get("institutionsPercentHeld")), "percent"),
            ("Institutions (float)", _pct(values.get("institutionsFloatPercentHeld")), "percent"),
            ("Institution count", values.get("institutionsCount"), "int"),
        ]))

    for attr, title in (("institutional_holders", "Top institutions"), ("mutualfund_holders", "Top funds")):
        df = getattr(t, attr)
        if isinstance(df, pd.DataFrame) and not df.empty:
            blocks.append(table(attr, title, [
                column("holder", "Holder"), column("shares", "Shares", "compact"),
                column("value", "Value", "compact"), column("pct", "% held", "percent"),
                column("chg", "Change", "pctchange"), column("date", "Reported", "date"),
            ], [row([r.get("Holder"), r.get("Shares"), r.get("Value"), _pct(r.get("pctHeld")),
                     _pct(r.get("pctChange")), r.get("Date Reported")]) for _, r in df.iterrows()]))

    ins = t.insider_transactions
    if isinstance(ins, pd.DataFrame) and not ins.empty:
        blocks.append(table("insiders", "Insider transactions", [
            column("date", "Date", "date"), column("insider", "Insider"), column("position", "Position"),
            column("text", "Transaction"), column("shares", "Shares", "compact"), column("value", "Value", "compact"),
        ], [row([r.get("Start Date"), r.get("Insider"), r.get("Position"), r.get("Text") or r.get("Transaction"),
                 r.get("Shares"), r.get("Value")], url=r.get("URL") or None)
            for _, r in ins.head(40).iterrows()]))

    return document(f"Holders — {symbol}", blocks, SOURCE, subtitle=symbol)


# MARK: OPT


@ttl_cache(120)
@_retry_locked
def options(symbol: str, expiry: str | None) -> dict[str, Any]:
    t = yf.Ticker(symbol)
    expiries = list(t.options)
    if not expiries:
        raise LookupError(f"no listed options for {symbol}")
    expiry = expiry if expiry in expiries else expiries[0]
    chain = t.option_chain(expiry)
    spot = cell(t.fast_info.get("lastPrice"))

    def chain_table(id: str, title: str, df: pd.DataFrame) -> dict[str, Any]:
        return table(id, title, [
            column("strike", "Strike", "price"), column("last", "Last", "price"), column("bid", "Bid", "price"),
            column("ask", "Ask", "price"), column("chg", "Chg %", "pctchange"), column("vol", "Volume", "int"),
            column("oi", "Open int", "int"), column("iv", "IV", "percent"), column("itm", "ITM"),
        ], [row([r.strike, r.lastPrice, r.bid, r.ask, r.percentChange, r.volume, r.openInterest,
                 _pct(r.impliedVolatility), "●" if r.inTheMoney else ""]) for r in df.itertuples()])

    return document(f"Options — {symbol}", [
        choices("expiry", "Expiry", [(e, f"OPT {e}") for e in expiries[:24]], expiry),
        kv(None, [("Underlying", spot, "price"), ("Expiry", expiry, "text"),
                  ("Days to expiry", (dt.date.fromisoformat(expiry) - dt.date.today()).days, "int")]),
        chain_table("calls", "Calls", chain.calls),
        chain_table("puts", "Puts", chain.puts),
    ], SOURCE, subtitle=symbol)


# MARK: MKT

MARKET = {
    "Equity indices": [
        ("^GSPC", "S&P 500"), ("^NDX", "Nasdaq 100"), ("^DJI", "Dow Jones"), ("^RUT", "Russell 2000"),
        ("^VIX", "VIX"), ("^STOXX50E", "Euro Stoxx 50"), ("^FTSE", "FTSE 100"), ("^GDAXI", "DAX"),
        ("^FCHI", "CAC 40"), ("^N225", "Nikkei 225"), ("^HSI", "Hang Seng"), ("000001.SS", "Shanghai Comp."),
    ],
    "US rates": [("^IRX", "13-week T-bill"), ("^FVX", "5-year Treasury"), ("^TNX", "10-year Treasury"),
                 ("^TYX", "30-year Treasury")],
    "Currencies": [
        ("DX-Y.NYB", "Dollar index"), ("EURUSD=X", "EUR/USD"), ("GBPUSD=X", "GBP/USD"), ("USDJPY=X", "USD/JPY"),
        ("USDCHF=X", "USD/CHF"), ("AUDUSD=X", "AUD/USD"), ("USDCAD=X", "USD/CAD"), ("USDCNY=X", "USD/CNY"),
    ],
    "Commodities": [
        ("CL=F", "WTI crude"), ("BZ=F", "Brent crude"), ("NG=F", "Natural gas"), ("GC=F", "Gold"),
        ("SI=F", "Silver"), ("HG=F", "Copper"), ("ZC=F", "Corn"), ("ZW=F", "Wheat"),
    ],
    "Crypto": [("BTC-USD", "Bitcoin"), ("ETH-USD", "Ether"), ("SOL-USD", "Solana")],
}


# Crypto rows open the live Binance chart rather than Yahoo's delayed one.
CRYPTO_CMD = {"BTC-USD": "BTC CRYPTO", "ETH-USD": "ETH CRYPTO", "SOL-USD": "SOL CRYPTO"}


@ttl_cache(60)
@_retry_locked
def market() -> dict[str, Any]:
    symbols = [s for group in MARKET.values() for s, _ in group]
    data = yf.download(symbols, period="7d", interval="1d", group_by="ticker", progress=False,
                       auto_adjust=False, threads=True)
    blocks = []
    for group, members in MARKET.items():
        rows = []
        for symbol, name in members:
            try:
                closes = data[symbol]["Close"].dropna()
            except KeyError:
                continue
            if len(closes) < 2:
                continue
            last, prev, first = float(closes.iloc[-1]), float(closes.iloc[-2]), float(closes.iloc[0])
            rows.append(row([name, symbol, last, last - prev, (last / prev - 1) * 100, (last / first - 1) * 100,
                             closes.index[-1]], cmd=f"{CRYPTO_CMD.get(symbol, symbol)} CHART"))
        blocks.append(table(group.lower().replace(" ", "-"), group, [
            column("name", "Name"), column("symbol", "Symbol"), column("last", "Last", "price"),
            column("chg", "Change", "change"), column("pct", "Chg %", "pctchange"),
            column("week", "5-day", "pctchange"), column("date", "As of", "date"),
        ], rows))
    return document("World markets", blocks, SOURCE, notes=["Daily closes; intraday values may lag."])


# MARK: MOVERS / SCRN

MOVER_KINDS = {
    "GAINERS": ("day_gainers", "Top gainers"),
    "LOSERS": ("day_losers", "Top losers"),
    "ACTIVE": ("most_actives", "Most active"),
    "SMALLCAP": ("small_cap_gainers", "Small-cap gainers"),
    "SHORTED": ("most_shorted_stocks", "Most shorted"),
    "UNDERVALUED": ("undervalued_large_caps", "Undervalued large caps"),
    "GROWTH": ("growth_technology_stocks", "Growth tech"),
}

QUOTE_COLUMNS = [
    column("symbol", "Symbol"), column("name", "Name"), column("price", "Price", "price"),
    column("chg", "Change", "change"), column("pct", "Chg %", "pctchange"), column("vol", "Volume", "compact"),
    column("mcap", "Mkt cap", "compact"), column("pe", "P/E", "number"),
]


def _quote_rows(quotes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [row([q.get("symbol"), q.get("shortName") or q.get("longName"), q.get("regularMarketPrice"),
                 q.get("regularMarketChange"), q.get("regularMarketChangePercent"), q.get("regularMarketVolume"),
                 q.get("marketCap"), q.get("trailingPE")], cmd=f"{q.get('symbol')} QUOTE")
            for q in quotes if q.get("symbol")]


@ttl_cache(120)
@_retry_locked
def movers(kind: str) -> dict[str, Any]:
    kind = kind.upper() if kind.upper() in MOVER_KINDS else "GAINERS"
    screener, title = MOVER_KINDS[kind]
    result = yf.screen(screener, count=50)
    return document("Market movers", [
        choices("kind", None, [(t, f"MOVERS {k}") for k, (_, t) in MOVER_KINDS.items()], title),
        table("movers", title, QUOTE_COLUMNS, _quote_rows(result.get("quotes", []))),
    ], SOURCE, notes=["US listings."])


SCREEN_FIELDS = {
    "MCAP": ("intradaymarketcap", 1.0),
    "PE": ("peratio.lasttwelvemonths", 1.0),
    "PB": ("pricebookratio.quarterly", 1.0),
    "DIVY": ("forward_dividend_yield", 1.0),
    "CHG": ("percentchange", 1.0),
    "VOL": ("dayvolume", 1.0),
    "BETA": ("beta", 1.0),
    "ROE": ("returnonequity.lasttwelvemonths", 1.0),
    "GROWTH": ("totalrevenues1yrgrowth.lasttwelvemonths", 1.0),
}
SECTORS = sorted(yf.screener.query.EQUITY_SCREENER_EQ_MAP["sector"])
SUFFIX = {"K": 1e3, "M": 1e6, "B": 1e9, "T": 1e12}
FILTER = re.compile(r"^(?P<field>[A-Z]+)(?P<op>>=|<=|>|<|=)(?P<value>.+)$")


def parse_filters(tokens: list[str]) -> tuple[Any, list[str]]:
    """`MCAP>10B PE<20 SECTOR=TECHNOLOGY` -> (EquityQuery, normalized tokens)."""
    clauses = [yf.EquityQuery("eq", ["region", "us"])]
    normalized = []
    for token in tokens:
        m = FILTER.match(token.upper())
        if not m:
            raise ValueError(f"bad filter {token!r}; use e.g. MCAP>10B PE<20 SECTOR=TECHNOLOGY")
        field, op, value = m["field"], m["op"], m["value"]
        if field == "SECTOR":
            match = next((s for s in SECTORS if s.upper().replace(" ", "") == value.replace("_", "")), None)
            if not match:
                raise ValueError(f"unknown sector {value}; use one of {', '.join(s.upper().replace(' ', '') for s in SECTORS)}")
            clauses.append(yf.EquityQuery("eq", ["sector", match]))
        elif field in SCREEN_FIELDS:
            mult = SUFFIX.get(value[-1], 1)
            number = float(value[:-1] if value[-1] in SUFFIX else value) * mult
            yf_op = {">": "gt", ">=": "gte", "<": "lt", "<=": "lte", "=": "eq"}[op]
            clauses.append(yf.EquityQuery(yf_op, [SCREEN_FIELDS[field][0], number]))
        else:
            raise ValueError(f"unknown field {field}; use {', '.join([*SCREEN_FIELDS, 'SECTOR'])}")
        normalized.append(f"{field}{op}{value}")
    return yf.EquityQuery("and", clauses) if len(clauses) > 1 else clauses[0], normalized


@ttl_cache(300)
@_retry_locked
def screen(filters: tuple[str, ...]) -> dict[str, Any]:
    tokens = list(filters) or ["MCAP>10B"]
    query, normalized = parse_filters(tokens)
    result = yf.screen(query, sortField="intradaymarketcap", sortAsc=False, size=100)
    presets = [
        ("Mega caps", "SCRN MCAP>200B"),
        ("Cheap large caps", "SCRN MCAP>10B PE<15"),
        ("Dividend payers", "SCRN MCAP>5B DIVY>3"),
        ("Tech", "SCRN MCAP>5B SECTOR=TECHNOLOGY"),
        ("Today's big movers", "SCRN MCAP>2B CHG>5"),
    ]
    return document("Equity screener", [
        choices("presets", "Presets", presets, None),
        text("Filters", " ".join(normalized) + "   ·   fields: " + " ".join([*SCREEN_FIELDS, "SECTOR"])
             + "   ·   e.g. SCRN MCAP>10B PE<20 SECTOR=HEALTHCARE"),
        table("results", f"Top {len(result.get('quotes', []))} by market cap",
              QUOTE_COLUMNS, _quote_rows(result.get("quotes", []))),
    ], SOURCE, notes=["US listings."])
