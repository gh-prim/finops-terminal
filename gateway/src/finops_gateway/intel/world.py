"""WORLD: what is happening, where, and which assets it touches.

Sources (all public, all worldwide, no key):
  GDELT 2.0 event files (15-min, geolocated, from world media) — conflict, protests, coercion
  GDACS (UN/EU)  — cyclones, floods, volcanoes, droughts, wildfires, with alert levels
  USGS           — earthquakes M5+
  IMF PortWatch  — daily transits through maritime chokepoints
  IODA           — national internet outages
  Kalshi         — prediction-market odds (economics, politics)
Every event is linked to entities (country, nearby chokepoint, names in its title) and
through them to exposed assets.
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import logging
import re
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from typing import Any

from ..cache import ttl_cache
from ..providers.http import get_json
from . import entities as ent

log = logging.getLogger(__name__)
UA = {"User-Agent": "Mozilla/5.0 finops-terminal"}


@dataclass
class Event:
    id: str
    source: str
    kind: str            # conflict | unrest | coercion | disaster | shipping | internet
    title: str
    time: float
    severity: int        # 1 watch · 2 notable · 3 major
    lat: float | None = None
    lon: float | None = None
    place: str | None = None
    detail: str | None = None
    url: str | None = None
    entities: list[str] = field(default_factory=list)

    def assets(self, limit: int = 4) -> list[str]:
        out: list[str] = []
        for id in self.entities:
            if (e := ent.get(id)) is not None:
                for a in e.assets:
                    if a.security not in out:
                        out.append(a.security)
        return out[:limit]

    def as_dict(self) -> dict[str, Any]:
        return {**asdict(self), "assets": self.assets()}


def _link(event: Event, country: ent.Entity | None) -> Event:
    ids: list[str] = []
    if country is not None:
        ids.append(country.id)
    if event.lat is not None and event.lon is not None:
        ids += ent.near(event.lat, event.lon)
    ids += ent.match_text(f"{event.title} {event.detail or ''}")
    event.entities = list(dict.fromkeys(ids))
    return event


def _fetch(url: str, timeout: float = 20) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as response:
        return response.read()


# MARK: GDELT event files

GDELT_ROOT = {
    "13": ("Threat", "coercion"), "14": ("Protest", "unrest"), "15": ("Military posture", "conflict"),
    "16": ("Relations cut", "coercion"), "17": ("Coercion / sanctions", "coercion"), "18": ("Assault", "conflict"),
    "19": ("Fighting", "conflict"), "20": ("Mass violence", "conflict"),
}


@ttl_cache(86400, maxsize=64)
def _gdelt_file(url: str) -> list[list[str]]:
    data = _fetch(url, timeout=30)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        text = z.read(z.namelist()[0]).decode("utf-8", "replace")
    return list(csv.reader(io.StringIO(text), delimiter="\t"))


def _gdelt_urls(files: int) -> list[str]:
    latest = _fetch("https://data.gdeltproject.org/gdeltv2/lastupdate.txt").decode().split()
    stamp = next(p for p in latest if p.endswith(".export.CSV.zip")).rsplit("/", 1)[1][:14]
    t = dt.datetime.strptime(stamp, "%Y%m%d%H%M%S")
    return [f"https://data.gdeltproject.org/gdeltv2/{(t - dt.timedelta(minutes=15 * i)):%Y%m%d%H%M%S}.export.CSV.zip"
            for i in range(files)]


def _headline(url: str) -> str:
    """A readable title from an article URL slug (GDELT events carry no headline)."""
    path = urllib.parse.urlparse(url).path.rstrip("/").rsplit("/", 1)[-1]
    path = re.sub(r"\.(html?|php|aspx?)$", "", path)
    words = [w for w in re.split(r"[-_.]+", path) if w and not re.fullmatch(r"[0-9a-f]{6,}|\d+", w, re.I)]
    return " ".join(words).capitalize()[:140] if len(words) >= 3 else ""


@ttl_cache(600)
def gdelt(hours: int = 3) -> list[Event]:
    """Conflict, unrest and coercion events over the last `hours`, clustered by place and type."""
    with ThreadPoolExecutor(max_workers=6) as pool:
        files = list(pool.map(lambda u: _try(_gdelt_file, u, []), _gdelt_urls(hours * 4)))
    clusters: dict[tuple[str, str], dict[str, Any]] = {}
    for rows in files:
        for r in rows:
            if len(r) < 61 or r[28] not in GDELT_ROOT or not r[56] or not r[52]:
                continue
            key = (r[52], GDELT_ROOT[r[28]][0])
            c = clusters.setdefault(key, {"articles": 0, "sources": 0, "goldstein": 0.0, "best": (0, ""), "row": r,
                                          "root": r[28], "time": 0.0})
            articles = int(r[33] or 0)
            c["articles"] += articles
            c["sources"] += int(r[32] or 0)
            c["goldstein"] = min(c["goldstein"], float(r[30] or 0))
            if articles > c["best"][0]:
                c["best"] = (articles, r[60])
            c["time"] = max(c["time"], dt.datetime.strptime(r[59], "%Y%m%d%H%M%S").replace(tzinfo=dt.UTC).timestamp())
    events = []
    for (place, label), c in clusters.items():
        if c["articles"] < 4:
            continue
        r = c["row"]
        severity = 3 if c["articles"] >= 40 or (c["root"] in ("19", "20") and c["articles"] >= 20) else 2 if c["articles"] >= 12 else 1
        url = c["best"][1]
        headline = _headline(url)
        country = ent.BY_FIPS.get(r[53])
        title = f"{label} · {place.split(',')[0]}" + (f": {headline}" if headline else "")
        events.append(_link(Event(
            id=f"gdelt:{place}:{label}", source="GDELT", kind=GDELT_ROOT[c["root"]][1], title=title, time=c["time"],
            severity=severity, lat=float(r[56]), lon=float(r[57]), place=place,
            detail=f"{c['articles']} articles · {c['sources']} sources · Goldstein {c['goldstein']:+.0f}", url=url,
        ), country))
    events.sort(key=lambda e: -int(e.detail.split()[0]))
    return events[:200]


# MARK: Disasters

GDACS_KIND = {"TC": "Tropical cyclone", "FL": "Flood", "VO": "Volcano", "DR": "Drought", "WF": "Wildfire", "EQ": "Earthquake"}


@ttl_cache(600)
def gdacs() -> list[Event]:
    data = get_json("https://www.gdacs.org/gdacsapi/api/events/geteventlist/EVENTS4APP", timeout=20)
    out = []
    for f in data.get("features", []):
        p = f.get("properties", {})
        if p.get("eventtype") == "EQ":
            continue  # USGS covers earthquakes in more detail
        level = {"Green": 1, "Orange": 2, "Red": 3}.get(p.get("alertlevel"), 1)
        lon, lat = (f.get("geometry", {}).get("coordinates") or [None, None])[:2]
        iso3 = (p.get("iso3") or "").upper()
        try:
            when = dt.datetime.fromisoformat(p.get("fromdate")).replace(tzinfo=dt.UTC).timestamp()
        except (TypeError, ValueError):
            when = time.time()
        severity = (p.get("severitydata") or {}).get("severitytext")
        out.append(_link(Event(
            id=f"gdacs:{p.get('eventtype')}:{p.get('eventid')}", source="GDACS", kind="disaster",
            title=p.get("name") or GDACS_KIND.get(p.get("eventtype"), "Disaster"), time=when, severity=level,
            lat=lat, lon=lon, place=p.get("country"), detail=f"{GDACS_KIND.get(p.get('eventtype'), '')} · {p.get('alertlevel')} alert"
            + (f" · {severity}" if severity else ""), url=(p.get("url") or {}).get("report"),
        ), ent.BY_ISO3.get(iso3)))
    return out


@ttl_cache(600)
def quakes(min_magnitude: float = 5.0) -> list[Event]:
    data = get_json("https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_week.geojson", timeout=20)
    out = []
    for f in data.get("features", []):
        p = f["properties"]
        mag = p.get("mag") or 0
        if mag < min_magnitude:
            continue
        lon, lat = f["geometry"]["coordinates"][:2]
        place = p.get("place") or ""
        country = ent.find(place.rsplit(",", 1)[-1].strip()) if "," in place else None
        out.append(_link(Event(
            id=f"usgs:{f['id']}", source="USGS", kind="disaster", title=f"M{mag:.1f} earthquake · {place}",
            time=(p.get("time") or 0) / 1000, severity=3 if mag >= 7 else 2 if mag >= 6 else 1, lat=lat, lon=lon,
            place=place, detail=("Tsunami warning · " if p.get("tsunami") else "") + f"depth {f['geometry']['coordinates'][2]:.0f} km",
            url=p.get("url"),
        ), country if country and country.kind == "country" else None))
    return out


# MARK: Shipping

PORTWATCH = ("https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/Daily_Chokepoints_Data/"
             "FeatureServer/0/query")


@ttl_cache(3600)
def chokepoints() -> list[dict[str, Any]]:
    """Per chokepoint: last 7 days of transits vs the 30 days before (PortWatch lags ~1 week)."""
    since = (dt.date.today() - dt.timedelta(days=60)).isoformat()
    names = [e.portwatch for e in ent.ENTITIES_LIST if e.portwatch]
    where = f"date >= '{since}' AND portname IN ({', '.join(repr(n) for n in names)})"
    data = get_json(PORTWATCH, {"where": where, "outFields": "date,portname,n_total,n_tanker,n_container",
                                "orderByFields": "date", "resultRecordCount": 4000, "f": "json"}, timeout=30)
    series: dict[str, list[dict[str, Any]]] = {}
    for f in data.get("features", []):
        a = f["attributes"]
        series.setdefault(a["portname"], []).append(a)
    out = []
    for e in ent.ENTITIES_LIST:
        rows = series.get(e.portwatch or "", [])
        if len(rows) < 20:
            continue
        last, base = rows[-7:], rows[-37:-7]
        avg = lambda rs, k: sum(r[k] or 0 for r in rs) / max(len(rs), 1)
        now, before = avg(last, "n_total"), avg(base, "n_total")
        out.append({"entity": e.id, "name": e.name, "date": rows[-1]["date"], "transits": now, "baseline": before,
                    "change": (now / before - 1) * 100 if before else None, "tankers": avg(last, "n_tanker"),
                    "containers": avg(last, "n_container"), "series": [(r["date"], r["n_total"]) for r in rows]})
    return out


def shipping_events() -> list[Event]:
    out = []
    for c in _try(chokepoints, None, []):
        change = c["change"]
        if change is None or change > -15:
            continue
        e = ent.get(c["entity"])
        out.append(Event(
            id=f"portwatch:{c['entity']}", source="IMF PortWatch", kind="shipping",
            title=f"{c['name']}: transits {change:+.0f}% vs prior month", time=_date_ts(c["date"]),
            severity=3 if change <= -35 else 2, lat=e.lat if e else None, lon=e.lon if e else None, place=c["name"],
            detail=f"{c['transits']:.0f} ships/day (7-day avg) vs {c['baseline']:.0f}", entities=[c["entity"], *(e.related if e else ())],
        ))
    return out


def _date_ts(value: Any) -> float:
    if isinstance(value, (int, float)):
        return value / 1000
    try:
        return dt.datetime.fromisoformat(str(value)).replace(tzinfo=dt.UTC).timestamp()
    except ValueError:
        return time.time()


# MARK: Internet

@ttl_cache(900)
def outages() -> list[Event]:
    now = int(time.time())
    data = get_json("https://api.ioda.inetintel.cc.gatech.edu/v2/outages/alerts",
                    {"from": now - 86400, "until": now, "entityType": "country", "limit": 500}, timeout=20)
    worst: dict[str, dict[str, Any]] = {}
    for a in data.get("data", []):
        code = (a.get("entity") or {}).get("code")
        if not code or a.get("level") not in ("critical", "warning"):
            continue
        if code not in worst or a.get("level") == "critical":
            worst[code] = a
    out = []
    for code, a in worst.items():
        country = ent.BY_ISO2.get(code)
        name = (a.get("entity") or {}).get("name") or code
        out.append(_link(Event(
            id=f"ioda:{code}", source="IODA", kind="internet", title=f"Internet disruption · {name}",
            time=float(a.get("time") or now), severity=2 if a.get("level") == "critical" else 1,
            lat=country.lat if country else None, lon=country.lon if country else None, place=name,
            detail=f"{a.get('datasource', '')} signal {a.get('level')}",
            url=f"https://ioda.inetintel.cc.gatech.edu/country/{code}",
        ), country))
    return out


# MARK: Prediction markets

@ttl_cache(900)
def predictions(limit: int = 30) -> list[dict[str, Any]]:
    data = get_json("https://api.elections.kalshi.com/trade-api/v2/events",
                    {"status": "open", "limit": 200, "with_nested_markets": "true"}, timeout=20)
    rows = []
    for e in data.get("events", []):
        if e.get("category") not in ("Economics", "Politics", "Financials", "World", "Elections", "Companies"):
            continue
        def num(m: dict[str, Any], key: str) -> float:
            try:
                return float(m.get(key) or 0)
            except (TypeError, ValueError):
                return 0.0

        markets = sorted(e.get("markets") or [], key=lambda m: -num(m, "volume_fp"))
        if not markets:
            continue
        m = markets[0]
        price = num(m, "last_price_dollars") or num(m, "yes_bid_dollars")
        rows.append({"title": e.get("title"), "market": m.get("yes_sub_title") or "", "category": e.get("category"),
                     "yes": price * 100, "change": (price - num(m, "previous_price_dollars")) * 100,
                     "volume": sum(num(x, "volume_fp") for x in markets), "volume24h": sum(num(x, "volume_24h_fp") for x in markets),
                     "close": m.get("close_time"), "url": f"https://kalshi.com/markets/{(e.get('series_ticker') or '').lower()}",
                     "entities": ent.match_text(e.get("title") or "")})
    rows.sort(key=lambda r: -(r["volume24h"] * 10 + r["volume"]))  # active markets first
    return rows[:limit]


# MARK: Feed

def _try(fn: Any, arg: Any, default: Any) -> Any:
    try:
        return fn(arg) if arg is not None else fn()
    except Exception as exc:  # one dead source must not take the feed down
        log.warning("world source %s failed: %s", getattr(fn, "__name__", fn), exc)
        return default


_lock = threading.Lock()


def feed() -> tuple[list[Event], list[str]]:
    """All events, newest-severe first, plus the sources that failed."""
    sources = {"GDELT": gdelt, "GDACS": gdacs, "USGS": quakes, "PortWatch": shipping_events, "IODA": outages}
    failed: list[str] = []
    events: list[Event] = []
    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        futures = {name: pool.submit(fn) for name, fn in sources.items()}
        for name, future in futures.items():
            try:
                events += future.result()
            except Exception as exc:
                log.warning("world source %s failed: %s", name, exc)
                failed.append(name)
    events.sort(key=lambda e: (-e.severity, -e.time))
    return events, failed


def for_entities(ids: set[str], limit: int = 30) -> list[Event]:
    events, _ = feed()
    return [e for e in events if ids & set(e.entities)][:limit]
