"""Yahoo Finance adapter (yfinance). Blocking calls; run them in a thread."""

from __future__ import annotations

import functools
import math
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, ParamSpec, TypeVar

import yfinance as yf

CACHE_DIR = Path(
    os.environ.get("FINOPS_CACHE_DIR", Path.home() / "Library/Application Support/finops-terminal")
) / "yfinance"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
yf.set_tz_cache_location(str(CACHE_DIR))

P = ParamSpec("P")
R = TypeVar("R")


def _retry_locked(fn: Callable[P, R]) -> Callable[P, R]:
    """yfinance's SQLite caches raise 'database is locked' under concurrent threads."""

    @functools.wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        for attempt in range(4):
            try:
                return fn(*args, **kwargs)
            except Exception as exc:  # yfinance wraps sqlite3.OperationalError inconsistently
                if "database is locked" not in str(exc) or attempt == 3:
                    raise
                time.sleep(0.1 * (attempt + 1))
        raise AssertionError("unreachable")

    return wrapper


# Range code -> (yfinance period, interval).
RANGES: dict[str, tuple[str, str]] = {
    "1D": ("1d", "5m"),
    "5D": ("5d", "15m"),
    "1M": ("1mo", "1h"),
    "3M": ("3mo", "1d"),
    "6M": ("6mo", "1d"),
    "YTD": ("ytd", "1d"),
    "1Y": ("1y", "1d"),
    "2Y": ("2y", "1d"),
    "5Y": ("5y", "1wk"),
    "10Y": ("10y", "1wk"),
    "MAX": ("max", "1mo"),
}


def _num(value: Any) -> float | None:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(f) or math.isinf(f) else f


@_retry_locked
def history(symbol: str, range_code: str) -> dict[str, Any]:
    if range_code not in RANGES:
        raise ValueError(f"unknown range {range_code!r}; use one of {', '.join(RANGES)}")
    period, interval = RANGES[range_code]
    df = yf.Ticker(symbol).history(period=period, interval=interval, auto_adjust=True)
    if df.empty:
        raise LookupError(f"no history for {symbol}")
    bars = []
    for ts, row in df.iterrows():
        close = _num(row["Close"])
        if close is None:
            continue
        bars.append(
            {
                "t": ts.timestamp(),
                "o": _num(row["Open"]),
                "h": _num(row["High"]),
                "l": _num(row["Low"]),
                "c": close,
                "v": _num(row["Volume"]),
            }
        )
    return {"symbol": symbol, "range": range_code, "interval": interval, "bars": bars}


@_retry_locked
def quote(symbol: str) -> dict[str, Any]:
    fi = yf.Ticker(symbol).fast_info
    last = _num(fi.get("lastPrice"))
    if last is None:
        raise LookupError(f"no quote for {symbol}")
    prev = _num(fi.get("previousClose"))
    change = last - prev if prev is not None else None
    return {
        "symbol": symbol,
        "last": last,
        "previousClose": prev,
        "change": change,
        "changePct": (change / prev * 100) if change is not None and prev else None,
        "open": _num(fi.get("open")),
        "dayHigh": _num(fi.get("dayHigh")),
        "dayLow": _num(fi.get("dayLow")),
        "volume": _num(fi.get("lastVolume")),
        "currency": fi.get("currency"),
        "exchange": fi.get("exchange"),
        "marketCap": _num(fi.get("marketCap")),
        "asOf": time.time(),
    }


def name(symbol: str) -> str | None:
    try:
        info = yf.Ticker(symbol).get_info()
    except Exception:
        return None
    return info.get("longName") or info.get("shortName")


@_retry_locked
def lookup(query: str, limit: int = 10) -> dict[str, Any]:
    results = yf.Search(query, max_results=limit, news_count=0).quotes
    return {
        "query": query,
        "results": [
            {
                "symbol": q.get("symbol"),
                "name": q.get("longname") or q.get("shortname"),
                "type": q.get("quoteType"),
                "exchange": q.get("exchDisp") or q.get("exchange"),
            }
            for q in results
            if q.get("symbol")
        ],
    }
