"""FRED (St. Louis Fed): macro series, release calendar and the Treasury curve."""

from __future__ import annotations

import datetime as dt
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from ..cache import ttl_cache
from ..config import settings
from ..documents import column, document, row, table
from .http import get_json

API = "https://api.stlouisfed.org/fred"
SOURCE = "FRED, Federal Reserve Bank of St. Louis"


class MissingKey(LookupError):
    pass


def _get(path: str, **params: Any) -> Any:
    if not settings.fred_api_key:
        raise MissingKey("FRED needs a free API key: get one at fred.stlouisfed.org/docs/api/api_key.html "
                         "and paste it in finops-terminal → Settings.")
    return get_json(f"{API}/{path}", {**params, "api_key": settings.fred_api_key, "file_type": "json"})


# (series id, label, units transform) — "pc1" = % change from a year ago.
DASHBOARD = [
    ("Inflation & growth", [
        ("CPIAUCSL", "CPI inflation (YoY)", "pc1"),
        ("CPILFESL", "Core CPI (YoY)", "pc1"),
        ("PCEPILFE", "Core PCE (YoY)", "pc1"),
        ("A191RL1Q225SBEA", "Real GDP growth (QoQ ann.)", "lin"),
        ("INDPRO", "Industrial production (YoY)", "pc1"),
        ("RSAFS", "Retail sales (YoY)", "pc1"),
    ]),
    ("Labor", [
        ("UNRATE", "Unemployment rate", "lin"),
        ("PAYEMS", "Nonfarm payrolls (monthly chg, k)", "chg"),
        ("ICSA", "Initial jobless claims", "lin"),
        ("JTSJOL", "Job openings (k)", "lin"),
    ]),
    ("Rates & money", [
        ("FEDFUNDS", "Fed funds rate", "lin"),
        ("DGS2", "2-year Treasury", "lin"),
        ("DGS10", "10-year Treasury", "lin"),
        ("T10Y2Y", "10y–2y spread", "lin"),
        ("MORTGAGE30US", "30-year mortgage", "lin"),
        ("BAMLH0A0HYM2", "High-yield spread", "lin"),
    ]),
    ("Sentiment & housing", [
        ("UMCSENT", "Consumer sentiment (UMich)", "lin"),
        ("HOUST", "Housing starts (k, ann.)", "lin"),
        ("VIXCLS", "VIX", "lin"),
        ("DCOILWTICO", "WTI crude ($)", "lin"),
    ]),
]

MAJOR_RELEASES = (
    "Employment Situation", "Consumer Price Index", "Gross Domestic Product", "Personal Income and Outlays",
    "Producer Price Index", "Advance Monthly Sales", "Industrial Production", "New Residential Construction",
    "Unemployment Insurance Weekly Claims", "Job Openings and Labor Turnover", "Surveys of Consumers",
    "FOMC", "Advance Durable Goods", "Existing Home Sales", "Construction Spending", "ISM",
)


def _observations(series_id: str, units: str = "lin", start: str | None = None, limit: int | None = None,
                  desc: bool = False) -> list[tuple[float, float]]:
    params: dict[str, Any] = {"series_id": series_id, "units": units, "sort_order": "desc" if desc else "asc"}
    if start:
        params["observation_start"] = start
    if limit:
        params["limit"] = limit
    obs = _get("series/observations", **params)["observations"]
    out = []
    for o in obs:
        if o["value"] in (".", ""):
            continue
        t = dt.datetime.fromisoformat(o["date"]).replace(tzinfo=dt.UTC).timestamp()
        out.append((t, float(o["value"])))
    return out


@ttl_cache(3600)
def dashboard() -> dict[str, Any]:
    def latest(item: tuple[str, str, str]) -> dict[str, Any] | None:
        sid, label, units = item
        obs = _observations(sid, units, limit=2, desc=True)
        if not obs:
            return None
        (t, v), prev = obs[0], (obs[1][1] if len(obs) > 1 else None)
        return row([label, v, prev, v - prev if prev is not None else None, t, sid], cmd=f"ECON {sid}")

    blocks: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        for group, items in DASHBOARD:
            rows = [r for r in pool.map(latest, items) if r]
            blocks.append(table(group.lower(), group, [
                column("name", "Indicator"), column("last", "Latest", "number"), column("prev", "Previous", "number"),
                column("chg", "Change", "change"), column("date", "Date", "date"), column("id", "Series"),
            ], rows))
    blocks.append(calendar())
    return document("Economy", blocks, SOURCE,
                    notes=["Click an indicator to chart it. Search any FRED series with ECON SEARCH <words>."])


def calendar(days: int = 21) -> dict[str, Any]:
    today = dt.date.today()
    data = _get("releases/dates", realtime_start=today.isoformat(),
                realtime_end=(today + dt.timedelta(days=days)).isoformat(),
                include_release_dates_with_no_data="true", order_by="release_date", sort_order="asc", limit=1000)
    rows = []
    for r in data.get("release_dates", []):
        name = r.get("release_name", "")
        if any(name.startswith(m) or m in name for m in MAJOR_RELEASES):
            t = dt.datetime.fromisoformat(r["date"]).replace(tzinfo=dt.UTC).timestamp()
            rows.append(row([t, name], url=f"https://fred.stlouisfed.org/release?rid={r['release_id']}"))
    return table("calendar", f"Release calendar (next {days} days)",
                 [column("date", "Date", "date"), column("release", "Release")], rows)


RANGE_START = {"1Y": 365, "2Y": 730, "5Y": 1826, "10Y": 3652, "20Y": 7305, "MAX": None}


@ttl_cache(3600, maxsize=128)
def series(series_id: str, range_code: str = "10Y", units: str = "lin") -> dict[str, Any]:
    meta = _get("series", series_id=series_id)["seriess"][0]
    days = RANGE_START.get(range_code, 3652)
    start = (dt.date.today() - dt.timedelta(days=days)).isoformat() if days else None
    obs = _observations(series_id, units, start=start)
    unit_label = {"pc1": "% change from a year ago", "chg": "change"}.get(units, meta.get("units", ""))
    return {
        "series": {
            "id": meta["id"], "title": meta["title"], "units": unit_label,
            "frequency": meta.get("frequency", ""), "lastUpdated": meta.get("last_updated", ""),
            "notes": (meta.get("notes") or "")[:1200],
        },
        "range": range_code,
        "transform": units,
        "observations": [{"t": t, "v": v} for t, v in obs],
        "source": SOURCE,
    }


@ttl_cache(3600, maxsize=64)
def search(text: str) -> dict[str, Any]:
    found = _get("series/search", search_text=text, limit=40, order_by="popularity", sort_order="desc")
    rows = [row([s["id"], s["title"], s.get("frequency_short"), s.get("units_short"),
                 dt.datetime.fromisoformat(s["observation_end"]).replace(tzinfo=dt.UTC).timestamp()],
                cmd=f"ECON {s['id']}") for s in found.get("seriess", [])]
    return document(f"FRED search — {text}", [
        table("results", None, [column("id", "Series"), column("title", "Title"), column("freq", "Freq"),
                                column("units", "Units"), column("end", "Last obs", "date")], rows),
    ], SOURCE)


TENORS = [("1M", "DGS1MO", 1 / 12), ("3M", "DGS3MO", 0.25), ("6M", "DGS6MO", 0.5), ("1Y", "DGS1", 1),
          ("2Y", "DGS2", 2), ("3Y", "DGS3", 3), ("5Y", "DGS5", 5), ("7Y", "DGS7", 7), ("10Y", "DGS10", 10),
          ("20Y", "DGS20", 20), ("30Y", "DGS30", 30)]


@ttl_cache(3600)
def curve() -> dict[str, Any]:
    start = (dt.date.today() - dt.timedelta(days=400)).isoformat()
    with ThreadPoolExecutor(max_workers=6) as pool:
        histories = dict(zip([t for t, _, _ in TENORS],
                             pool.map(lambda x: _observations(x[1], start=start), TENORS)))

    def at(days_ago: int) -> tuple[float, list[dict[str, Any]]]:
        target = (dt.datetime.now(dt.UTC) - dt.timedelta(days=days_ago)).timestamp()
        points, when = [], 0.0
        for tenor, _, years in TENORS:
            obs = [o for o in histories[tenor] if o[0] <= target]
            if obs:
                points.append({"tenor": tenor, "years": years, "yield": obs[-1][1]})
                when = max(when, obs[-1][0])
        return when, points

    curves = []
    for label, days in (("Latest", 0), ("1 month ago", 30), ("6 months ago", 182), ("1 year ago", 365)):
        when, points = at(days)
        if points:
            curves.append({"label": label, "date": when, "points": points})
    return {"curves": curves, "source": SOURCE}

