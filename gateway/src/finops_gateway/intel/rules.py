"""RULE: cross-source alerts. A rule fires when all its conditions hold at once.

Condition kinds (fields in brackets):
  price      [security, op, value]   session change % of a security
  chokepoint [entity, op, value]     transits vs the prior month, % (IMF PortWatch)
  conflict   [entity, severity]      conflict / coercion events linked to an entity (GDELT)
  unrest     [entity, severity]      protests and unrest
  disaster   [entity, severity]      cyclones, floods, volcanoes, quakes… (GDACS, USGS)
  quake      [entity, value]         earthquake of at least this magnitude near the entity (USGS)
  outage     [entity]                national internet disruption (IODA)
  keyword    [text]                  a word in the latest world events or crypto headlines
"""

from __future__ import annotations

import json
import re
import time
from typing import Any

from .. import securities
from ..providers import binance, crypto_news, yahoo
from . import entities as ent
from . import world

KIND_FOR = {"conflict": {"conflict", "coercion"}, "unrest": {"unrest"}, "disaster": {"disaster"}}

PRESETS: list[dict[str, Any]] = [
    {"id": "hormuz-oil", "name": "Hormuz disruption with oil rising",
     "conditions": [{"kind": "chokepoint", "entity": "HORMUZ", "op": "<", "value": -15},
                    {"kind": "price", "security": "CL1 CMD", "op": ">", "value": 2}]},
    {"id": "red-sea", "name": "Red Sea shipping disrupted",
     "conditions": [{"kind": "chokepoint", "entity": "BABELMANDEB", "op": "<", "value": -20}]},
    {"id": "taiwan-chips", "name": "Taiwan tension hitting chips",
     "conditions": [{"kind": "conflict", "entity": "TW", "severity": 2},
                    {"kind": "price", "security": "TSM US EQ", "op": "<", "value": -3}]},
    {"id": "mideast-gold", "name": "Major Middle East escalation, gold bid",
     "conditions": [{"kind": "conflict", "entity": "IR", "severity": 3},
                    {"kind": "price", "security": "GC1 CMD", "op": ">", "value": 1}]},
    {"id": "quake-taiwan", "name": "M6.5+ earthquake near Taiwan (fabs)",
     "conditions": [{"kind": "quake", "entity": "TW", "value": 6.5}]},
    {"id": "quake-japan", "name": "M7+ earthquake near Japan",
     "conditions": [{"kind": "quake", "entity": "JP", "value": 7}]},
    {"id": "russia-blackout", "name": "Internet blackout in Russia or Iran",
     "conditions": [{"kind": "outage", "entity": "RU"}]},
    {"id": "risk-off", "name": "Risk-off: S&P down 2% and VIX up 15%",
     "conditions": [{"kind": "price", "security": "SPX IDX", "op": "<", "value": -2},
                    {"kind": "price", "security": "VIX IDX", "op": ">", "value": 15}]},
    {"id": "btc-crash", "name": "Bitcoin down 7% in a day",
     "conditions": [{"kind": "price", "security": "BTC CRYPTO", "op": "<", "value": -7}]},
]


def describe(c: dict[str, Any]) -> str:
    name = lambda id: (e.name if (e := ent.get(id or "")) else id or "?")
    match c.get("kind"):
        case "price": return f"{c.get('security')} {c.get('op')} {float(c.get('value', 0)):+g}% today"
        case "chokepoint": return f"{name(c.get('entity'))} transits {c.get('op')} {float(c.get('value', 0)):+g}% vs last month"
        case "conflict" | "unrest" | "disaster":
            return f"{c['kind'].title()} linked to {name(c.get('entity'))}, severity ≥ {c.get('severity', 1)}"
        case "quake": return f"Earthquake M{float(c.get('value', 6)):g}+ near {name(c.get('entity'))}"
        case "outage": return f"Internet disruption in {name(c.get('entity'))}"
        case "keyword": return f"“{c.get('text')}” in world events or crypto headlines"
    return str(c)


def _change_pct(typed: str) -> float | None:
    sec = securities.resolve(typed)
    q = binance.quote(sec.symbol) if sec.provider == "binance" else yahoo.quote(sec.symbol)
    return q.get("changePct")


def _compare(observed: float | None, op: str, value: float) -> bool:
    return observed is not None and (observed > value if op == ">" else observed < value)


def check(c: dict[str, Any], events: list[world.Event]) -> tuple[bool, str]:
    """(met, what was observed)."""
    kind = c.get("kind")
    try:
        if kind == "price":
            v = _change_pct(c["security"])
            return _compare(v, c.get("op", ">"), float(c.get("value", 0))), f"{c['security']} {v:+.2f}%" if v is not None else "no quote"
        if kind == "chokepoint":
            cp = next((x for x in world.chokepoints() if x["entity"] == c.get("entity")), None)
            v = cp["change"] if cp else None
            return _compare(v, c.get("op", "<"), float(c.get("value", 0))), (f"{v:+.0f}% (data to {cp['date']})" if v is not None else "no data")
        if kind in KIND_FOR:
            hits = [e for e in events if e.kind in KIND_FOR[kind] and c.get("entity") in e.entities
                    and e.severity >= int(c.get("severity", 1))]
            return bool(hits), (hits[0].title if hits else "nothing")
        if kind == "quake":
            hits = []
            for e in events:
                m = re.match(r"M(\d+(?:\.\d+)?) earthquake", e.title)
                if m and float(m.group(1)) >= float(c.get("value", 6)) and _near(e, c.get("entity")):
                    hits.append(e)
            return bool(hits), (hits[0].title if hits else "none")
        if kind == "outage":
            hits = [e for e in events if e.kind == "internet" and c.get("entity") in e.entities]
            return bool(hits), (hits[0].title if hits else "no disruption")
        if kind == "keyword":
            word = str(c.get("text", "")).lower()
            titles = [e.title for e in events] + [i["title"] for i in crypto_news.headlines()[0][:60]]
            hit = next((t for t in titles if word and word in t.lower()), None)
            return hit is not None, hit or "not seen"
    except Exception as exc:
        return False, f"unavailable ({exc})"
    return False, "unknown condition"


def _near(e: world.Event, entity_id: str | None) -> bool:
    target = ent.get(entity_id or "")
    if target is None:
        return False
    if target.id in e.entities:
        return True
    return (target.lat is not None and e.lat is not None and
            ent._distance(e.lat, e.lon, target.lat, target.lon) <= 600)


def evaluate(raw: str) -> dict[str, Any]:
    rules = json.loads(raw or "[]")
    events, failed = world.feed()
    out = []
    for rule in rules:
        results = [(c, *check(c, events)) for c in rule.get("conditions", [])]
        out.append({"id": rule.get("id"), "met": bool(results) and all(met for _, met, _ in results),
                    "conditions": [{"text": describe(c), "met": met, "observed": seen} for c, met, seen in results]})
    return {"rules": out, "checked": time.time(), "unavailable": failed}


def presets() -> dict[str, Any]:
    return {"presets": [{**p, "conditions": [{**c, "text": describe(c)} for c in p["conditions"]]} for p in PRESETS],
            "entities": [{"id": e.id, "name": e.name, "kind": e.kind} for e in ent.ENTITIES_LIST]}
