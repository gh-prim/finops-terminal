"""WORLD and LINK screens."""

from __future__ import annotations

from typing import Any

from .. import securities
from ..documents import choices, column, document, graph, kv, map_block, row, series, table
from ..providers import views
from . import entities as ent
from . import world

SOURCE = "GDELT, GDACS, USGS, IMF PortWatch, IODA, Kalshi · links curated in finops (intel/entities.py)"

KINDS = {
    "ALL": ("Everything", None),
    "CONFLICT": ("Conflict", {"conflict"}),
    "UNREST": ("Unrest", {"unrest"}),
    "COERCION": ("Sanctions & threats", {"coercion"}),
    "DISASTER": ("Disasters", {"disaster"}),
    "SHIPPING": ("Shipping", {"shipping"}),
    "INTERNET": ("Internet", {"internet"}),
    "ODDS": ("Prediction markets", None),
}


def yahoo(typed: str) -> str | None:
    try:
        return securities.resolve(typed).yahoo_symbol
    except ValueError:
        return None


def performance(typed: list[str]) -> dict[str, tuple[float | None, float | None]]:
    """typed security -> (1-day %, 1-month %)."""
    pairs = [(t, y) for t in typed if (y := yahoo(t))]
    if not pairs:
        return {}
    try:
        prices = views._cached_closes(tuple(sorted({y for _, y in pairs})), "3mo")
    except Exception:
        return {}
    out = {}
    for t, y in pairs:
        if y in prices:
            out[t] = (views.period_return(prices[y], 1), views.period_return(prices[y], 21))
    return out


def _event_cmd(e: world.Event) -> str | None:
    return f"LINK {e.entities[0]}" if e.entities else None


def _event_row(e: world.Event) -> dict[str, Any]:
    return row([e.time, "●" * e.severity, e.kind, e.title, e.place, ", ".join(e.entities[:3]), " ".join(e.assets(3))],
               cmd=None if e.url else _event_cmd(e), url=e.url)


EVENT_COLUMNS = [column("t", "Time", "datetime"), column("sev", "Sev"), column("kind", "Type"), column("title", "Event"),
                 column("place", "Where"), column("links", "Linked to"), column("assets", "Exposed assets")]


def _map_points(events: list[world.Event]) -> list[dict[str, Any]]:
    return [{"lat": e.lat, "lon": e.lon, "label": e.title[:80], "detail": e.detail, "kind": e.kind,
             "severity": e.severity, "cmd": _event_cmd(e), "url": e.url}
            for e in events if e.lat is not None and e.lon is not None]


def world_screen(kind: str = "ALL", min_severity: int = 1) -> dict[str, Any]:
    kind = kind if kind in KINDS else "ALL"
    tabs = choices("kind", None, [(label, f"WORLD {k}") for k, (label, _) in KINDS.items()], KINDS[kind][0])
    if kind == "ODDS":
        rows = [row([r["title"], r["market"], r["yes"], r["change"], r["volume"], r["category"]], url=r["url"])
                for r in world.predictions(40)]
        return document("World · prediction markets", [tabs, table("odds", "Kalshi: most traded open markets", [
            column("q", "Question"), column("m", "Outcome"), column("yes", "Yes %", "number"),
            column("chg", "Change (pts)", "change"), column("vol", "Contracts", "compact"), column("cat", "Category"),
        ], rows)], "Kalshi", notes=["Prices are implied probabilities. Click a row to open the market."], refresh=300)

    events, failed = world.feed()
    wanted = KINDS[kind][1]
    shown = [e for e in events if (wanted is None or e.kind in wanted) and e.severity >= min_severity]
    counts = {k: sum(1 for e in events if e.kind in (v or set())) for k, (_, v) in KINDS.items() if v}
    blocks: list[dict[str, Any]] = [
        tabs,
        kv("Last hours", [(KINDS[k][0], n, "int") for k, n in counts.items()]
           + [("Major (●●●)", sum(1 for e in events if e.severity == 3), "int")]),
        map_block("map", f"{len(shown)} events · colour = type · size = severity", _map_points(shown)),
    ]
    if kind in ("ALL", "SHIPPING"):
        cps = world.chokepoints()
        blocks.append(table("chokepoints", "Maritime chokepoints · daily transits, 7-day average vs prior 30 days", [
            column("name", "Chokepoint"), column("n", "Ships/day", "number"), column("base", "Prior month", "number"),
            column("chg", "Change", "pctchange"), column("tank", "Tankers/day", "number"), column("box", "Containers/day", "number"),
            column("date", "Data to"),
        ], [row([c["name"], c["transits"], c["baseline"], c["change"], c["tankers"], c["containers"], c["date"]],
                cmd=f"LINK {c['entity']}") for c in cps]))
    blocks.append(table("events", "Events, most severe first", EVENT_COLUMNS, [_event_row(e) for e in shown[:120]]))
    notes = ["Click an event to open its source, or a map point / chokepoint to see the entity and its exposed assets (LINK)."]
    if failed:
        notes.append(f"Unavailable right now: {', '.join(failed)}.")
    return document("World monitor", blocks, SOURCE, notes=notes, refresh=300)


# MARK: LINK

def link_screen(query: str) -> dict[str, Any]:
    """An entity (country, chokepoint, commodity…) or a security, with everything it connects to."""
    entity = ent.find(query)
    if entity is None:
        return _security_links(query)

    assets = [a.security for a in entity.assets]
    perf = performance(assets)
    related = [e for id in entity.related if (e := ent.get(id))]
    events = world.for_entities({entity.id, *entity.related}, 25)
    center = {"label": entity.name, "detail": entity.kind.title(),
              "lines": [f"{len(assets)} exposed assets", f"{len(related)} linked entities", f"{len(events)} recent events"]}
    asset_nodes = [{"label": a.security, "detail": a.why[:28], "value": perf.get(a.security, (None, None))[0],
                    "cmd": f"{a.security} CHART"} for a in entity.assets]
    related_nodes = [{"label": e.name, "detail": e.kind, "cmd": f"LINK {e.id}"} for e in related]
    event_nodes = [{"label": e.title[:30], "detail": e.place or e.source, "value": None, "cmd": f"LINK {e.entities[0]}"}
                   for e in events[:6] if e.entities]
    blocks: list[dict[str, Any]] = [
        choices("go", None, [("World monitor", "WORLD")] + [(e.name, f"LINK {e.id}") for e in related[:6]], None),
        graph("links", None, center, [
            {"title": "Exposed assets · 1D %", "side": "left", "nodes": asset_nodes},
            {"title": "Linked entities", "side": "right", "nodes": related_nodes},
            {"title": "Recent events", "side": "bottom", "nodes": event_nodes},
        ]),
        table("assets", "Why these assets", [column("sec", "Asset"), column("why", "Link"), column("d1", "1D", "pctchange"),
                                             column("m1", "1M", "pctchange"), column("dir", "Tends to")], [
            row([a.security, a.why, *perf.get(a.security, (None, None)), "rise on shocks" if a.sign > 0 else "fall on shocks"],
                cmd=f"{a.security} CHART") for a in entity.assets]),
    ]
    if entity.portwatch:
        cp = next((c for c in world.chokepoints() if c["entity"] == entity.id), None)
        if cp:
            blocks.insert(2, series("transits", f"{entity.name} · ships per day (IMF PortWatch)",
                                    [{"label": "Transits", "points": [(world._date_ts(d), n) for d, n in cp["series"]]}]))
    if entity.lat is not None:
        blocks.append(map_block("map", None, _map_points(events)
                                + [{"lat": entity.lat, "lon": entity.lon, "label": entity.name, "kind": "focus", "severity": 3}]))
    blocks.append(table("events", "Recent events involving it", EVENT_COLUMNS, [_event_row(e) for e in events]))
    return document(f"Links · {entity.name}", blocks, SOURCE, subtitle=entity.kind, refresh=300)


def _security_links(typed: str) -> dict[str, Any]:
    try:
        sec = securities.resolve(typed)
    except ValueError:
        raise LookupError(f"nothing named {typed!r}: try a country, chokepoint, commodity (LINK HORMUZ) or a security") from None
    profile = views.info(sec.yahoo_symbol) if sec.asset_class in (None, "EQ", "ETF") else {}
    exposure = ent.exposure(sec.typed, profile)
    if not exposure:
        raise LookupError(f"no known world exposure for {sec.typed}")
    ids = {id for id, _, _ in exposure}
    events = world.for_entities(ent.watch_set(ids), 25)
    center = {"label": sec.typed, "detail": profile.get("shortName") or "", "lines": [
        f"{profile.get('sector') or sec.asset_class or ''}", f"HQ {profile.get('country') or '—'}"]}
    nodes = [{"label": (e.name if (e := ent.get(id)) else id), "detail": f"{w * 100:.0f}% · {why}"[:28], "cmd": f"LINK {id}"}
             for id, w, why in exposure]
    return document(f"Links · {sec.typed}", [
        graph("links", None, center, [
            {"title": "World exposure (weight · reason)", "side": "left", "nodes": nodes},
            {"title": "Recent events on those links", "side": "right",
             "nodes": [{"label": e.title[:30], "detail": e.place or e.source, "cmd": f"LINK {e.entities[0]}"} for e in events[:8]]},
        ]),
        table("exposure", "Exposure", [column("e", "Entity"), column("w", "Weight", "percent"), column("why", "Reason")],
              [row([ent.get(id).name if ent.get(id) else id, w * 100, why], cmd=f"LINK {id}") for id, w, why in exposure]),
        table("events", "Recent events on its exposures", EVENT_COLUMNS, [_event_row(e) for e in events]),
    ], SOURCE, subtitle="world exposure", notes=[
        "Curated exposures for large caps; others are inferred from headquarters country and industry."], refresh=300)
