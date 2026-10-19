"""Binance spot market data: public REST endpoints (blocking; run them in a thread).

Only the market-data host is used (no account, no key). Live prices come from
the WebSocket streams in `binance_stream.py`.
"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from ..cache import ttl_cache
from ..documents import bars, choices, column, document, kv, row, table, treemap
from ..securities import split_pair
from .http import HTTPError, get_json
from .yahoo import INTERVALS as YAHOO_INTERVALS
from .yahoo import RANGES, clamp_range, range_days

REST = "https://api.binance.com/api/v3"
SOURCE = "Binance spot market data"

# Interval token -> (Binance interval, seconds per bar).
INTERVALS: dict[str, tuple[str, int]] = {
    "1MIN": ("1m", 60),
    "5MIN": ("5m", 300),
    "15MIN": ("15m", 900),
    "30MIN": ("30m", 1800),
    "1H": ("1h", 3600),
    "4H": ("4h", 14400),
    "1DAY": ("1d", 86400),
    "1WK": ("1w", 604800),
    "1MO": ("1M", 2_592_000),
}
# Same default bar size per range as the Yahoo charts.
AUTO_INTERVAL = {"5m": "5MIN", "15m": "15MIN", "1h": "1H", "1d": "1DAY", "1wk": "1WK", "1mo": "1MO"}
MAX_BATCHES = 10         # 1000 klines each
GENESIS_MS = 1_500_000_000_000  # mid-2017, before Binance opened

STABLECOINS = {"USDT", "USDC", "FDUSD", "TUSD", "DAI", "USDP", "BUSD", "USDE", "USD1", "XUSD", "RLUSD", "PYUSD",
               "EUR", "EURI", "AEUR", "TRY", "BRL"}
LEVERAGED = ("UP", "DOWN", "BULL", "BEAR")

NAMES = {
    "BTC": "Bitcoin", "ETH": "Ethereum", "BNB": "BNB", "SOL": "Solana", "XRP": "XRP", "DOGE": "Dogecoin",
    "ADA": "Cardano", "TRX": "TRON", "AVAX": "Avalanche", "LINK": "Chainlink", "DOT": "Polkadot",
    "TON": "Toncoin", "SHIB": "Shiba Inu", "LTC": "Litecoin", "BCH": "Bitcoin Cash", "XLM": "Stellar",
    "SUI": "Sui", "NEAR": "NEAR Protocol", "APT": "Aptos", "UNI": "Uniswap", "PEPE": "Pepe", "ICP": "Internet Computer",
    "ETC": "Ethereum Classic", "HBAR": "Hedera", "FIL": "Filecoin", "ATOM": "Cosmos", "ARB": "Arbitrum",
    "OP": "Optimism", "INJ": "Injective", "AAVE": "Aave", "TAO": "Bittensor", "WLD": "Worldcoin",
    "ENA": "Ethena", "SEI": "Sei", "TIA": "Celestia", "RENDER": "Render", "FET": "Artificial Superintelligence",
    "MKR": "Maker", "ALGO": "Algorand", "VET": "VeChain", "POL": "Polygon", "WIF": "dogwifhat", "BONK": "Bonk",
    "TRUMP": "Official Trump", "HYPE": "Hyperliquid", "PAXG": "PAX Gold", "WBTC": "Wrapped Bitcoin",
}


def typed(pair: str) -> str:
    """The terminal form of a pair: BTCUSDT -> "BTC CRYPTO", ETHEUR -> "ETH EUR CRYPTO"."""
    base, quote_asset = split_pair(pair)
    return f"{base} CRYPTO" if quote_asset == "USDT" else f"{base} {quote_asset} CRYPTO"


def name(pair: str) -> str:
    base, quote = split_pair(pair)
    return f"{NAMES.get(base, base)} / {quote}" if quote else pair


def _f(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _get(path: str, **params: Any) -> Any:
    try:
        return get_json(f"{REST}/{path}", params or None, timeout=15)
    except HTTPError as exc:
        if exc.status == 400 and "Invalid symbol" in str(exc):
            raise LookupError(f"{params.get('symbol')} is not traded on Binance") from None
        raise


def quote_from_ticker(t: dict[str, Any]) -> dict[str, Any]:
    """Map a 24h ticker (REST or stream payload) to the gateway's quote shape.
    Crypto never closes, so "previous close" is the price 24 hours ago."""
    rest = "lastPrice" in t
    pair = t["symbol"] if rest else t["s"]
    last = _f(t["lastPrice"] if rest else t["c"])
    open_ = _f(t["openPrice"] if rest else t["o"])
    change = last - open_ if last is not None and open_ is not None else None
    return {
        "symbol": pair,
        "last": last,
        "previousClose": open_,
        "change": change,
        "changePct": change / open_ * 100 if change is not None and open_ else None,
        "open": open_,
        "dayHigh": _f(t["highPrice"] if rest else t["h"]),
        "dayLow": _f(t["lowPrice"] if rest else t["l"]),
        "volume": _f(t["volume"] if rest else t["v"]),
        "currency": split_pair(pair)[1] or None,
        "exchange": "Binance",
        "marketCap": None,
        "asOf": (t["closeTime"] if rest else t["E"]) / 1000,
    }


def quote(pair: str) -> dict[str, Any]:
    return quote_from_ticker(_get("ticker/24hr", symbol=pair))


def history(pair: str, range_code: str, interval_code: str | None = None) -> dict[str, Any]:
    if range_code not in RANGES:
        raise ValueError(f"unknown range {range_code!r}; use one of {', '.join(RANGES)}")
    if interval_code and interval_code not in INTERVALS:
        raise ValueError(f"unknown interval {interval_code!r}; use one of {', '.join(INTERVALS)}")
    if interval_code in YAHOO_INTERVALS:
        range_code = clamp_range(range_code, interval_code)  # same limits as stock charts, e.g. 1MIN -> 5D
    interval_code = interval_code or AUTO_INTERVAL[RANGES[range_code][1]]
    interval, seconds = INTERVALS[interval_code]
    now_ms = int(time.time() * 1000)
    days = range_days(range_code)
    start_ms = now_ms - days * 86_400_000 if days else GENESIS_MS

    # Fetch the most recent MAX_BATCHES windows of 1000 bars in parallel.
    span_ms = 1000 * seconds * 1000
    windows = max(1, min(MAX_BATCHES, -(-(now_ms - start_ms) // span_ms)))
    with ThreadPoolExecutor(max_workers=windows) as pool:
        batches = list(pool.map(lambda k: _get("klines", symbol=pair, interval=interval, limit=1000,
                                                endTime=now_ms - k * span_ms), range(windows)))
    seen: set[int] = set()
    rows = [r for batch in reversed(batches) for r in batch if not (r[0] in seen or seen.add(r[0]))]
    rows = [r for r in rows if r[0] >= start_ms]
    if not rows:
        raise LookupError(f"no history for {pair}")
    return {
        "symbol": pair, "range": range_code, "interval": interval_code, "intervalSeconds": seconds,
        "bars": [{"t": r[0] / 1000, "o": _f(r[1]), "h": _f(r[2]), "l": _f(r[3]), "c": _f(r[4]), "v": _f(r[5])}
                 for r in rows],
    }


def lookup(query: str, limit: int = 10) -> list[dict[str, Any]]:
    """Pairs whose base asset or name matches, most liquid first."""
    q = query.upper().strip()
    if len(q) < 2:
        return []
    try:
        tickers = _tickers()
    except Exception:
        return []  # lookup must keep working (Yahoo results) if Binance is unreachable
    hits = [t for t in tickers if (base := split_pair(t["symbol"])[0]) == q
            or (len(q) >= 3 and (q in NAMES.get(base, "").upper() or t["symbol"].startswith(q)))]
    hits.sort(key=lambda t: -(_f(t["quoteVolume"]) or 0) * _usd_rate(split_pair(t["symbol"])[1]))
    return [{"symbol": typed(t["symbol"]), "name": name(t["symbol"]),
             "type": "CRYPTO", "exchange": "Binance"} for t in hits[:limit]]


# MARK: CRYPTO screens


@ttl_cache(15)
def _tickers() -> list[dict[str, Any]]:
    return [t for t in _get("ticker/24hr") if _f(t.get("lastPrice")) and _f(t.get("quoteVolume"))]


def _usd_rate(quote_asset: str) -> float:
    if quote_asset.startswith("USD") or quote_asset == "FDUSD":
        return 1.0
    for t in _tickers():
        if t["symbol"] == f"{quote_asset}USDT":
            return _f(t["lastPrice"]) or 0.0
    return 0.0


def _listed(t: dict[str, Any], quote_asset: str) -> bool:
    base, q = split_pair(t["symbol"])
    return q == quote_asset and base not in STABLECOINS and not any(
        base.endswith(s) and len(base) > len(s) for s in LEVERAGED)


QUOTES = ("USDT", "USDC", "EUR", "BTC")


def market(quote_asset: str = "USDT", count: int = 100) -> dict[str, Any]:
    quote_asset = quote_asset if quote_asset in QUOTES else "USDT"
    listed = sorted((t for t in _tickers() if _listed(t, quote_asset)), key=lambda t: -(_f(t["quoteVolume"]) or 0))
    top = listed[:count]
    def pair_cmd(base: str) -> str:
        return typed(base + quote_asset)

    tiles, rows = [], []
    for t in top:
        base = split_pair(t["symbol"])[0]
        tiles.append({"label": base, "detail": NAMES.get(base, base), "weight": _f(t["quoteVolume"]),
                      "value": _f(t["priceChangePercent"]), "cmd": f"{pair_cmd(base)} CHART"})
        rows.append(row([base, NAMES.get(base, ""), _f(t["lastPrice"]), _f(t["priceChangePercent"]),
                         _f(t["highPrice"]), _f(t["lowPrice"]), _f(t["quoteVolume"]), t.get("count")],
                        cmd=pair_cmd(base)))
    from .crypto_news import latest  # late import: crypto_news imports NAMES from here
    news_rows = [row([i["time"], i["title"], i["publisher"]], url=i["link"]) for i in latest(8)]
    up = sum(1 for t in listed if (_f(t["priceChangePercent"]) or 0) > 0)
    movers = sorted(top[:60], key=lambda t: -(_f(t["priceChangePercent"]) or 0))
    return document("Crypto market", [
        choices("quote", "Quoted in", [(q, f"CRYPTO {q}") for q in QUOTES], quote_asset),
        kv("Breadth (24h)", [("Pairs", len(listed), "int"), ("Advancing", up, "int"),
                              ("Declining", len(listed) - up, "int"),
                              (f"Volume ({quote_asset})", sum(_f(t["quoteVolume"]) or 0 for t in listed), "compact")]),
        treemap("heat", f"Top {min(40, len(tiles))} by 24h volume · area = volume · colour = 24h change",
                [{"label": "Spot", "items": tiles[:40]}]),
        bars("gainers", "Best and worst 24h (among the 60 most traded)",
             [{"label": split_pair(t["symbol"])[0], "value": _f(t["priceChangePercent"]),
               "cmd": f"{pair_cmd(split_pair(t['symbol'])[0])} CHART"} for t in movers[:8] + movers[-8:]], kind="pctchange"),
        table("headlines", "Latest headlines · NEWS CRYPTO for more", [
            column("time", "Time", "datetime"), column("title", "Headline"), column("source", "Source")], news_rows),
        table("pairs", f"Top {len(rows)} {quote_asset} pairs by 24h volume", [
            column("sym", "Coin"), column("name", "Name"), column("last", "Last", "price"),
            column("chg", "24h", "pctchange"), column("hi", "24h high", "price"), column("lo", "24h low", "price"),
            column("vol", f"Volume {quote_asset}", "compact"), column("n", "Trades", "compact"),
        ], rows),
    ], SOURCE, notes=["Live: refreshes every 10 s. Click a coin for its order book, a tile for its chart, a headline to read it."],
        refresh=10, layout="split")


def detail(pair: str) -> dict[str, Any]:
    base, quote_asset = split_pair(pair)
    form = typed(pair)
    t = _get("ticker/24hr", symbol=pair)
    book = _get("depth", symbol=pair, limit=15)
    trades = _get("trades", symbol=pair, limit=25)
    bids, asks = book["bids"], book["asks"]
    best_bid, best_ask = _f(bids[0][0]) if bids else None, _f(asks[0][0]) if asks else None
    spread = best_ask - best_bid if best_bid and best_ask else None
    depth_rows = [row([_f(b[1]) if b else None, _f(b[0]) if b else None, _f(a[0]) if a else None,
                       _f(a[1]) if a else None])
                  for b, a in zip(bids + [None] * (15 - len(bids)), asks + [None] * (15 - len(asks)))]
    trade_rows = [row([tr["time"] / 1000, "Sell" if tr["isBuyerMaker"] else "Buy", _f(tr["price"]), _f(tr["qty"]),
                       _f(tr["quoteQty"])]) for tr in reversed(trades)]
    return document(name(pair), [
        choices("go", None, [("Chart", f"{form} CHART"), ("Quote", f"{form} QUOTE"), ("News", f"{form} NEWS"),
                             ("Crypto market", "CRYPTO")], None),
        kv("Last 24 hours", [("Last", _f(t["lastPrice"]), "price"), ("Change", _f(t["priceChangePercent"]), "pctchange"),
                             ("High", _f(t["highPrice"]), "price"), ("Low", _f(t["lowPrice"]), "price"),
                             ("VWAP", _f(t["weightedAvgPrice"]), "price"),
                             (f"Volume ({base})", _f(t["volume"]), "compact"),
                             (f"Volume ({quote_asset})", _f(t["quoteVolume"]), "compact"),
                             ("Trades", t.get("count"), "compact")]),
        kv("Top of book", [("Bid", best_bid, "price"), ("Ask", best_ask, "price"), ("Spread", spread, "price"),
                           ("Spread (bp)", spread / best_ask * 10_000 if spread and best_ask else None, "number")]),
        table("book", "Order book (15 levels)", [column("bq", f"Bid size ({base})", "number"), column("bid", "Bid", "price"),
                                                 column("ask", "Ask", "price"), column("aq", f"Ask size ({base})", "number")],
              depth_rows),
        table("trades", "Recent trades", [column("t", "Time", "datetime"), column("side", "Taker"),
                                          column("px", "Price", "price"), column("q", f"Size ({base})", "number"),
                                          column("v", f"Value ({quote_asset})", "compact")], trade_rows),
    ], SOURCE, subtitle=pair, notes=["Live: refreshes every 2 s. The chart and quote stream every trade."], refresh=2)
