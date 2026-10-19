"""STUDY: what does an asset do after a kind of event? (an "event study")

Triggers:
  WHEN <security> >3 | <-2    days the trigger security moved more than the threshold (%)
  WHEN QUAKE <entity> [6.5]   earthquakes of at least that magnitude within 600 km (USGS, since 2000)
  DATES 2024-04-13,2024-10-01 explicit dates
Output: average path from 5 sessions before to 20 after, forward returns at +1/+5/+20,
hit rates, and the same statistics for an ordinary day, so the edge (or lack of it) is visible.
"""

from __future__ import annotations

import datetime as dt
import re
import statistics
from typing import Any

from .. import securities
from ..cache import ttl_cache
from ..documents import choices, column, document, kv, row, series, table
from ..providers import binance, yahoo
from ..providers.http import get_json
from . import entities as ent

HORIZONS = (1, 5, 20)
PRE, POST = 5, 20

PRESETS = [
    ("Oil jumps > 3%", "WHEN CL1 CMD >3"),
    ("Oil drops < -3%", "WHEN CL1 CMD <-3"),
    ("S&P 500 falls < -2%", "WHEN SPX IDX <-2"),
    ("VIX spikes > 20%", "WHEN VIX IDX >20"),
    ("Gold jumps > 2%", "WHEN GC1 CMD >2"),
    ("Bitcoin drops < -7%", "WHEN BTC CRYPTO <-7"),
    ("Dollar index > 1%", "WHEN DXY IDX >1"),
    ("Quakes M6.5+ near Taiwan", "WHEN QUAKE TAIWAN 6.5"),
    ("Quakes M6.5+ near Japan", "WHEN QUAKE JAPAN 6.5"),
]


@ttl_cache(3600, maxsize=64)
def _daily(typed: str) -> list[tuple[dt.date, float]]:
    sec = securities.resolve(typed)
    if sec.provider == "binance":
        bars = binance.history(sec.symbol, "MAX", "1DAY")["bars"]
    else:
        bars = yahoo.history(sec.symbol, "MAX", "1DAY")["bars"]
    return [(dt.datetime.fromtimestamp(b["t"], dt.UTC).date(), b["c"]) for b in bars if b.get("c")]


@ttl_cache(86400, maxsize=32)
def _quakes(entity_id: str, magnitude: float) -> list[tuple[dt.date, str]]:
    e = ent.get(entity_id)
    if e is None or e.lat is None:
        raise LookupError(f"no location for {entity_id}")
    data = get_json("https://earthquake.usgs.gov/fdsnws/event/1/query", {
        "format": "geojson", "starttime": "2000-01-01", "minmagnitude": magnitude, "latitude": e.lat,
        "longitude": e.lon, "maxradiuskm": 600, "orderby": "time-asc"}, timeout=30)
    return [(dt.datetime.fromtimestamp(f["properties"]["time"] / 1000, dt.UTC).date(),
             f"M{f['properties']['mag']:.1f} {f['properties']['place']}") for f in data.get("features", [])]


def parse(args: list[str]) -> tuple[str, Any]:
    """('price', (typed, op, threshold)) | ('quake', (entity, magnitude)) | ('dates', [date])."""
    if not args:
        return "price", ("SPX IDX", "<", -2.0)
    if args[0] == "DATES":
        dates = [dt.date.fromisoformat(d) for d in re.split(r"[,\s]+", " ".join(args[1:])) if d]
        if not dates:
            raise ValueError("Use: STUDY DATES 2024-04-13,2024-10-01")
        return "dates", dates
    body = args[1:] if args[0] == "WHEN" else args
    if body and body[0] == "QUAKE":
        entity = ent.find(" ".join(t for t in body[1:] if not re.fullmatch(r"\d+(\.\d+)?", t)))
        magnitude = next((float(t) for t in body[1:] if re.fullmatch(r"\d+(\.\d+)?", t)), 6.5)
        if entity is None or entity.lat is None:
            raise ValueError("Use: STUDY WHEN QUAKE <country or chokepoint> [magnitude], e.g. WHEN QUAKE TAIWAN 6.5")
        return "quake", (entity.id, magnitude)
    text = " ".join(body)
    m = re.match(r"^(.*?)\s*([<>])\s*(-?\d+(?:\.\d+)?)\s*%?$", text)
    if not m:
        raise ValueError("Use: <asset> STUDY WHEN <trigger security> >3  (or <-2), WHEN QUAKE TAIWAN 6.5, or DATES …")
    trigger = m.group(1).strip() or "SPX IDX"
    securities.resolve(trigger)
    return "price", (trigger, m.group(2), float(m.group(3)))


def _event_dates(kind: str, spec: Any) -> tuple[list[tuple[dt.date, str]], str]:
    if kind == "dates":
        return [(d, d.isoformat()) for d in spec], f"{len(spec)} chosen dates"
    if kind == "quake":
        entity_id, magnitude = spec
        name = ent.get(entity_id).name
        return _quakes(entity_id, magnitude), f"earthquakes M{magnitude:g}+ within 600 km of {name} (USGS)"
    typed, op, threshold = spec
    closes = _daily(typed)
    out = []
    for (d0, c0), (d1, c1) in zip(closes, closes[1:]):
        r = (c1 / c0 - 1) * 100
        if (op == ">" and r > threshold) or (op == "<" and r < threshold):
            out.append((d1, f"{typed} {r:+.1f}%"))
    return out, f"days {typed} moved {op} {threshold:+g}%"


def _dedupe(events: list[tuple[dt.date, str]], gap: int = 5) -> list[tuple[dt.date, str]]:
    """Clusters (aftershocks, consecutive selloff days) count once: keep the first of each run."""
    out: list[tuple[dt.date, str]] = []
    for d, label in sorted(events):
        if not out or (d - out[-1][0]).days > gap:
            out.append((d, label))
    return out


def study(target: str, args: list[str]) -> dict[str, Any]:
    target_sec = securities.resolve(target)
    kind, spec = parse(args)
    raw, description = _event_dates(kind, spec)
    events = _dedupe(raw)
    closes = _daily(target_sec.typed)
    dates = [d for d, _ in closes]
    prices = [c for _, c in closes]

    def first_index_on_or_after(d: dt.date) -> int | None:
        lo, hi = 0, len(dates)
        while lo < hi:
            mid = (lo + hi) // 2
            if dates[mid] < d:
                lo = mid + 1
            else:
                hi = mid
        return lo if lo < len(dates) else None

    paths: list[list[float]] = []
    forward: dict[int, list[float]] = {h: [] for h in HORIZONS}
    reaction: list[float] = []
    rows = []
    for d, label in events:
        i = first_index_on_or_after(d)
        if i is None or i - PRE - 1 < 0 or i + POST >= len(prices):
            continue
        base = prices[i - 1]  # close before the event session
        path = [(prices[i + k] / base - 1) * 100 for k in range(-PRE, POST + 1)]
        paths.append(path)
        # What a trader could still capture: from the close of the event session onwards.
        fwd = {h: (prices[i + h] / prices[i] - 1) * 100 for h in HORIZONS}
        for h in HORIZONS:
            forward[h].append(fwd[h])
        reaction.append(path[PRE])
        rows.append(row([d.isoformat(), label, path[PRE], fwd[1], fwd[5], fwd[20]]))
    if not paths:
        raise LookupError(f"no {description} with enough {target_sec.typed} history around them")

    def stats(values: list[float]) -> tuple[float, float, float]:
        return statistics.fmean(values), statistics.median(values), sum(v > 0 for v in values) / len(values) * 100

    # An ordinary day: from every session's close, same horizons.
    baseline = {h: [(prices[i + h] / prices[i] - 1) * 100 for i in range(len(prices) - h)] for h in HORIZONS}
    avg_path = [statistics.fmean(p[k] for p in paths) for k in range(PRE + POST + 1)]
    med_path = [statistics.median(p[k] for p in paths) for k in range(PRE + POST + 1)]
    r_mean, r_median, r_hit = stats(reaction)
    summary = [row(["Event session (reaction)", r_mean, r_median, r_hit, None, None, None])]
    for h in HORIZONS:
        mean, median, hit = stats(forward[h])
        b_mean, _, b_hit = stats(baseline[h])
        summary.append(row([f"Next {h} session{'s' if h > 1 else ''}", mean, median, hit, b_mean, b_hit, mean - b_mean]))

    trigger_label = {"price": lambda s: f"{s[0]} {s[1]} {s[2]:+g}%", "quake": lambda s: f"QUAKE {s[0]} {s[1]:g}",
                     "dates": lambda s: "DATES"}[kind](spec)
    return document(f"Event study · {target_sec.typed} after {trigger_label}", [
        choices("presets", "Try", [(label, f"{target_sec.typed} STUDY {cmd}") for label, cmd in PRESETS], None),
        kv("Sample", [("Events", len(paths), "int"), ("First", rows[0]["cells"][0], "text"),
                      ("Last", rows[-1]["cells"][0], "text"), ("Trigger", description, "text")]),
        series("path", f"Average move of {target_sec.typed} around the event (% from the prior close; day 0 = event session)", [
            {"label": "Average", "points": [[k - PRE, v] for k, v in enumerate(avg_path)]},
            {"label": "Median", "points": [[k - PRE, v] for k, v in enumerate(med_path)]},
        ], kind="number", x_kind="number"),
        table("summary", "From the event session's close, vs an ordinary day", [
            column("h", "Horizon"), column("avg", "Average", "pctchange"), column("med", "Median", "pctchange"),
            column("hit", "% up", "percent"), column("base", "Ordinary day avg", "pctchange"),
            column("bhit", "Ordinary % up", "percent"), column("edge", "Difference", "pctchange"),
        ], summary),
        table("events", "Each event", [column("d", "Date"), column("what", "Trigger"), column("d0", "Event day", "pctchange"),
                                       column("d1", "Next 1", "pctchange"), column("d5", "Next 5", "pctchange"),
                                       column("d20", "Next 20", "pctchange")], rows[::-1]),
    ], "Prices: Yahoo Finance / Binance · earthquakes: USGS", notes=[
        "Events closer than 5 days apart count once. Past reactions are not a forecast; small samples are noisy.",
        "Syntax: <asset> STUDY WHEN <security> >3 | <-2 · WHEN QUAKE <country> 6.5 · DATES 2024-04-13,2024-10-01",
    ])
