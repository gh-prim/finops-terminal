"""Yahoo Finance adapter (yfinance). Blocking calls; run them in a thread."""

from __future__ import annotations

import datetime as dt
import functools
import math
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, ParamSpec, TypeVar

import pandas as pd
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


# Explicit bar intervals: token -> (yfinance interval, max lookback days, seconds per bar).
INTERVALS: dict[str, tuple[str, int | None, int]] = {
    "1MIN": ("1m", 7, 60),
    "5MIN": ("5m", 59, 300),
    "15MIN": ("15m", 59, 900),
    "30MIN": ("30m", 59, 1800),
    "1H": ("60m", 729, 3600),
    "4H": ("60m", 729, 14400),   # resampled from 1h bars
    "1DAY": ("1d", None, 86400),
    "1WK": ("1wk", None, 604800),
}
AUTO_INTERVAL = {"5m": "5MIN", "15m": "15MIN", "1h": "1H", "1d": "1DAY", "1wk": "1WK", "1mo": "1MO"}
RANGE_ORDER = ["1D", "5D", "1M", "3M", "6M", "YTD", "1Y", "2Y", "5Y", "10Y", "MAX"]


def range_days(code: str) -> int | None:
    if code == "YTD":
        today = dt.date.today()
        return (today - dt.date(today.year, 1, 1)).days + 1
    return {"1D": 1, "5D": 5, "1M": 31, "3M": 92, "6M": 183, "1Y": 365, "2Y": 730, "5Y": 1826, "10Y": 3652}.get(code)


def clamp_range(range_code: str, interval_code: str) -> str:
    """Largest range not exceeding what Yahoo serves for this interval."""
    max_days = INTERVALS[interval_code][1]
    if max_days is None:
        return range_code
    days = range_days(range_code)
    if days is not None and days <= max_days:
        return range_code
    allowed = [r for r in RANGE_ORDER if (range_days(r) or 10**9) <= max_days]
    return allowed[-1]


def _bars(df: pd.DataFrame) -> list[dict[str, Any]]:
    bars = []
    for ts, row in df.iterrows():
        close = _num(row["Close"])
        if close is None:
            continue
        bars.append({"t": ts.timestamp(), "o": _num(row["Open"]), "h": _num(row["High"]), "l": _num(row["Low"]),
                     "c": close, "v": _num(row["Volume"])})
    return bars


def _four_hour(df: pd.DataFrame) -> pd.DataFrame:
    """Group 1h bars into 4-bar chunks per session day (US: 9:30–13:30, 13:30–16:00)."""
    day = df.index.normalize()
    chunk = df.groupby(day).cumcount() // 4
    grouped = df.groupby([day, chunk])
    out = pd.DataFrame({
        "Open": grouped["Open"].first(), "High": grouped["High"].max(), "Low": grouped["Low"].min(),
        "Close": grouped["Close"].last(), "Volume": grouped["Volume"].sum(),
    })
    out.index = pd.DatetimeIndex([g.index[0] for _, g in grouped])  # keep the exchange time zone
    return out


@_retry_locked
def history(symbol: str, range_code: str, interval_code: str | None = None) -> dict[str, Any]:
    if range_code not in RANGES:
        raise ValueError(f"unknown range {range_code!r}; use one of {', '.join(RANGES)}")
    if interval_code and interval_code not in INTERVALS:
        raise ValueError(f"unknown interval {interval_code!r}; use one of {', '.join(INTERVALS)}")
    if interval_code:
        range_code = clamp_range(range_code, interval_code)
        period, interval = RANGES[range_code][0], INTERVALS[interval_code][0]
    else:
        period, interval = RANGES[range_code]
        interval_code = AUTO_INTERVAL.get(interval, interval.upper())
    df = yf.Ticker(symbol).history(period=period, interval=interval, auto_adjust=True)
    if df.empty:
        raise LookupError(f"no history for {symbol}")
    if interval_code == "4H":
        df = _four_hour(df)
    seconds = INTERVALS.get(interval_code, (None, None, 2_592_000))[2]
    return {"symbol": symbol, "range": range_code, "interval": interval_code, "intervalSeconds": seconds,
            "bars": _bars(df)}


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
