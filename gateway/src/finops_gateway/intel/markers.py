"""Event markers for charts: what happened while the price moved.

news (the security's headlines), earnings dates, major US macro releases, and world
events on the security's exposures (country, chokepoint, commodity).
"""

from __future__ import annotations

import datetime as dt
import re
import time
from typing import Any

import yfinance as yf

from .. import securities
from ..cache import ttl_cache
from ..providers import crypto_news, views
from ..providers.yahoo import _retry_locked, range_days
from ..securities import split_pair
from . import entities as ent
from . import world

MACRO = re.compile(r"\b(CPI|Consumer Price|Nonfarm|Non-Farm|Unemployment Rate|Fed Interest Rate|FOMC|Interest Rate Decision|"
                   r"GDP|PCE|Retail Sales|ISM Manufacturing)\b", re.IGNORECASE)


def _marker(t: float, kind: str, title: str, detail: str | None = None, url: str | None = None,
            cmd: str | None = None) -> dict[str, Any]:
    return {"t": t, "kind": kind, "title": title, "detail": detail, "url": url, "cmd": cmd}


@ttl_cache(900, maxsize=128)
@_retry_locked
def _news(symbol: str) -> list[dict[str, Any]]:
    return [_marker(n["providerPublishTime"], "news", n["title"], n.get("publisher"), n.get("link"))
            for n in yf.Search(symbol, max_results=1, news_count=40).news if n.get("providerPublishTime") and n.get("title")]


@ttl_cache(21600, maxsize=128)
@_retry_locked
def _earnings(symbol: str) -> list[dict[str, Any]]:
    try:
        df = yf.Ticker(symbol).get_earnings_dates(limit=16)
    except Exception:
        return []
    if df is None or df.empty:
        return []
    out = []
    for ts, r in df.iterrows():
        surprise = r.get("Surprise(%)")
        detail = f"EPS {r.get('Reported EPS')} vs {r.get('EPS Estimate')} est." if r.get("Reported EPS") == r.get("Reported EPS") else "upcoming"
        if surprise == surprise and surprise is not None:
            detail += f" ({surprise:+.1f}%)"
        out.append(_marker(ts.timestamp(), "earnings", "Earnings", detail, cmd=None))
    return out


@ttl_cache(3600, maxsize=16)
def _macro(days: int) -> list[dict[str, Any]]:
    today = dt.date.today()
    try:
        df = views._calendar_frame("ECO", today - dt.timedelta(days=days), today + dt.timedelta(days=1))
    except Exception:
        return []
    out = []
    for name, r in df.iterrows():
        if r.get("Region") != "US" or not MACRO.search(str(name)):
            continue
        when = r.get("Event Time")
        if when is None or when != when:
            continue
        actual, expected = r.get("Actual"), r.get("Expected")
        detail = f"actual {actual} vs {expected} expected" if actual == actual and actual is not None else "scheduled"
        out.append(_marker(when.timestamp(), "macro", f"US {name}", detail, cmd="ECAL ECO WEEK US"))
    return out


def markers(typed: str, range_code: str = "1Y") -> dict[str, Any]:
    sec = securities.resolve(typed)
    days = range_days(range_code) or 3650
    since = time.time() - days * 86400
    out: list[dict[str, Any]] = []
    if sec.provider == "binance":
        base = split_pair(sec.symbol)[0]
        items, _ = crypto_news.headlines()
        out += [_marker(i["time"], "news", i["title"], i["publisher"], i["link"]) for i in items
                if i["time"] and crypto_news.mentions(i, base)]
    else:
        out += _news(sec.yahoo_symbol)
        if sec.asset_class in (None, "EQ"):
            out += _earnings(sec.yahoo_symbol)
    if days <= 120:
        out += _macro(min(days, 60))
    profile = views.info(sec.yahoo_symbol) if sec.asset_class in (None, "EQ", "ETF") else {}
    ids = ent.watch_set({id for id, _, _ in ent.exposure(sec.typed, profile)})
    if ids:
        try:
            out += [_marker(e.time, "world", e.title, e.detail, e.url, f"LINK {e.entities[0]}")
                    for e in world.for_entities(ids, 40) if e.severity >= 2]
        except Exception:
            pass
    out = [m for m in out if m["t"] >= since and m["t"] <= time.time() + 86400]
    out.sort(key=lambda m: m["t"])
    return {"security": sec.typed, "markers": out[-150:]}
