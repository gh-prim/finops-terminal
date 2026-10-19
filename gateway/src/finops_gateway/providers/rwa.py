"""RWA: tokenized real-world assets.

Live prices for the RWA tokens Binance lists (gold tokens, RWA platforms) come from the same
Binance feed as CRYPTO, so their charts stream. Market sizes and the long tail (tokenized
treasuries, money-market funds, private credit, stocks) come from CoinGecko's free categories.
Tokenized stocks are compared with the real share (premium/discount; useful on weekends).
"""

from __future__ import annotations

import threading
import time
from typing import Any

from ..cache import ttl_cache
from ..documents import choices, column, document, donut, kv, row, table, treemap  # noqa: F401
from . import binance, yahoo
from .http import get_json

SOURCE = "Binance (live tokens) · CoinGecko categories · Yahoo Finance (underlying shares, COMEX gold)"

CATEGORIES = {
    "GOLD": ("tokenized-gold", "Tokenized gold"),
    "TREASURIES": ("tokenized-treasuries", "Tokenized treasuries"),
    "MMF": ("tokenized-money-market-fund-mmfs", "Tokenized money-market funds"),
    "CREDIT": ("tokenized-private-credit", "Tokenized private credit"),
    "STOCKS": ("tokenized-stock", "Tokenized stocks"),
    "ETFS": ("tokenized-exchange-traded-funds-etfs", "Tokenized ETFs"),
    "COMMODITIES": ("tokenized-commodities", "Tokenized commodities"),
}

# RWA tokens with a Binance USDT market: (base, what it is).
BINANCE_RWA = [
    ("PAXG", "Paxos Gold: 1 token = 1 oz LBMA gold"),
    ("XAUT", "Tether Gold: 1 token = 1 oz gold"),
    ("ONDO", "Ondo Finance: tokenized treasuries (USDY, OUSG)"),
    ("PLUME", "Plume: RWA chain"),
    ("SYRUP", "Maple: institutional private credit"),
    ("CFG", "Centrifuge: on-chain credit, tokenized funds"),
    ("POLYX", "Polymesh: securities-token chain"),
    ("OM", "MANTRA: RWA chain"),
    ("USUAL", "Usual: treasury-backed stablecoin protocol"),
    ("PENDLE", "Pendle: yield tokenization (RWA yields)"),
    ("LINK", "Chainlink: oracles and proof of reserve for RWAs"),
]

_cg_lock = threading.Lock()
_cg_next = 0.0


def _coingecko(path: str, params: dict[str, Any]) -> Any:
    """CoinGecko's free API allows a few calls a minute: space them out."""
    global _cg_next
    with _cg_lock:
        wait = _cg_next - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _cg_next = time.monotonic() + 6.0
    return get_json(f"https://api.coingecko.com/api/v3/{path}", params, headers={"User-Agent": "finops-terminal"}, timeout=20)


@ttl_cache(1800)
def categories() -> dict[str, dict[str, Any]]:
    """Every CoinGecko category's market cap and 24h change, in one call."""
    return {c["id"]: c for c in _coingecko("coins/categories", {})}


@ttl_cache(900, maxsize=16)
def category(cat_id: str, count: int = 60) -> list[dict[str, Any]]:
    return _coingecko("coins/markets", {"vs_currency": "usd", "category": cat_id, "order": "market_cap_desc",
                                        "per_page": count, "price_change_percentage": "7d"})


@ttl_cache(600)
def _gold_future() -> float | None:
    try:
        return yahoo.quote("GC=F").get("last")
    except Exception:
        return None


def _binance_rows() -> list[dict[str, Any]]:
    tickers = {t["symbol"]: t for t in binance._tickers()}
    rows = []
    for base, what in BINANCE_RWA:
        t = tickers.get(f"{base}USDT")
        if not t:
            continue
        f = binance._f
        rows.append(row([base, f(t["lastPrice"]), f(t["priceChangePercent"]), f(t["quoteVolume"])],
                        cmd=f"{base} CRYPTO CHART"))
    return rows


def overview() -> dict[str, Any]:
    """Split layout: the market by category as a treemap on the left, figures and live tokens on the right."""
    try:
        cats = categories()
    except Exception:
        cats = {}
    sizes = [(key, label, cats[cat_id].get("market_cap") or 0, cats[cat_id].get("market_cap_change_24h"))
             for key, (cat_id, label) in CATEGORIES.items() if cat_id in cats and cats[cat_id].get("market_cap")]
    rwa_all = cats.get("real-world-assets-rwa") or {}
    gold = _gold_future()
    tickers = {t["symbol"]: t for t in binance._tickers()}
    premium = []
    for base in ("PAXG", "XAUT"):
        if (t := tickers.get(f"{base}USDT")) and gold:
            price = binance._f(t["lastPrice"])
            premium.append((f"{base} vs COMEX", (price / gold - 1) * 100 if price else None, "pctchange"))
    return document("Real-world assets", [
        treemap("market", "Tokenized market by category · area = market cap · colour = 24h · click to open", [
            {"label": "Categories", "items": [
                {"label": label.replace("Tokenized ", "").capitalize(), "detail": f"{cap / 1e9:.1f} B$",
                 "weight": cap, "value": change, "cmd": f"RWA {key}"} for key, label, cap, change in sizes]}]),
        _tabs("OVERVIEW"),
        kv("Market", [("All RWA tokens", rwa_all.get("market_cap"), "compact"),
                      ("24h", rwa_all.get("market_cap_change_24h"), "pctchange"),
                      ("COMEX gold", gold, "price"), *premium]),
        table("live", "Live on Binance · click for the streaming chart", [
            column("sym", "Token"), column("last", "Last", "price"), column("chg", "24h", "pctchange"),
            column("vol", "Vol USDT", "compact"),
        ], _binance_rows()),
    ], SOURCE, notes=["Gold tokens trade around the clock; COMEX gold is a futures price (contango makes it slightly higher)."],
        refresh=15, layout="split")


def _tabs(selected: str) -> dict[str, Any]:
    items = [("Overview", "RWA")] + [(label.replace("Tokenized ", "").capitalize(), f"RWA {key}")
                                     for key, (_, label) in CATEGORIES.items()]
    current = "Overview" if selected == "OVERVIEW" else CATEGORIES[selected][1].replace("Tokenized ", "").capitalize()
    return choices("cat", None, items, current)


def _underlying(symbol: str, name: str) -> str | None:
    """xStocks/Ondo-style tickers: TSLAX, AAPLON, CRCLB… -> the share's ticker."""
    s = symbol.upper()
    for suffix in ("ON", "X", "B"):
        if s.endswith(suffix) and len(s) > len(suffix) + 1:
            return s[: -len(suffix)]
    return None


def category_screen(key: str) -> dict[str, Any]:
    cat_id, label = CATEGORIES[key]
    coins = category(cat_id)
    binance_bases = {base for base, _ in BINANCE_RWA}
    stock = key in ("STOCKS", "ETFS")
    underlying_prices: dict[str, float | None] = {}
    if stock:
        for c in coins[:30]:
            if (u := _underlying(c.get("symbol") or "", c.get("name") or "")) and u not in underlying_prices:
                try:
                    underlying_prices[u] = yahoo.quote(u).get("last")
                except Exception:
                    underlying_prices[u] = None
    rows = []
    for c in coins:
        sym = (c.get("symbol") or "").upper()
        price = c.get("current_price")
        cells = [sym, price, c.get("price_change_percentage_24h"), c.get("market_cap")]
        if stock:
            u = _underlying(sym, c.get("name") or "")
            ref = underlying_prices.get(u) if u else None
            cells += [(price / ref - 1) * 100 if price and ref else None]
        cmd = f"{sym} CRYPTO CHART" if sym in binance_bases else (f"{_underlying(sym, '')} US EQ CHART" if stock and _underlying(sym, '') else None)
        rows.append(row(cells, cmd=cmd, url=None if cmd else f"https://www.coingecko.com/en/coins/{c.get('id')}"))
    columns = [column("sym", "Token"), column("px", "Price", "price"), column("d1", "24h", "pctchange"),
               column("cap", "Mkt cap", "compact")]
    if stock:
        columns += [column("prem", "vs share", "pctchange")]
    total = sum(c.get("market_cap") or 0 for c in coins)
    return document(label, [
        treemap("caps", "Market cap · colour = 24h change · click to open", [{"label": label, "items": [
            {"label": (c.get("symbol") or "").upper(), "detail": c.get("name"), "weight": c.get("market_cap") or 0,
             "value": c.get("price_change_percentage_24h"), "cmd": cmd}
            for c, cmd in zip(coins[:40], [r.get("cmd") for r in rows[:40]]) if c.get("market_cap")]}]),
        _tabs(key),
        kv("Category", [("Market cap (listed)", total, "compact"), ("Tokens", len(coins), "int"),
                        ("Largest", (coins[0].get("name") if coins else None), "text")]),
        table("tokens", f"Top {min(len(rows), 18)} by market cap", columns, rows[:18]),
    ], SOURCE, notes=(["vs share = token price vs the real share (Yahoo); on weekends it is the market's guess for Monday."]
                      if stock else []), refresh=300, layout="split")


def rwa(kind: str = "OVERVIEW") -> dict[str, Any]:
    kind = kind.upper() if kind else "OVERVIEW"
    if kind in CATEGORIES:
        return category_screen(kind)
    return overview()
