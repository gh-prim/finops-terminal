"""CASE feeds and EXPO (portfolio exposure to the world)."""

from __future__ import annotations

from typing import Any

import yfinance as yf

from .. import securities
from ..cache import ttl_cache
from ..documents import bars, column, document, kv, map_block, row, table
from ..providers import binance, crypto_news, views, yahoo
from ..providers.yahoo import _retry_locked
from . import entities as ent
from . import world
from .screens import EVENT_COLUMNS, _event_row, _map_points

SOURCE = "GDELT, GDACS, USGS, IMF PortWatch, IODA · exposures curated in finops · prices Yahoo/Binance"


# MARK: CASE — a living investigation feed

@ttl_cache(900, maxsize=64)
@_retry_locked
def _yahoo_news(query: str) -> list[dict[str, Any]]:
    return [n for n in yf.Search(query, max_results=1, news_count=15).news if n.get("title")]


def case_feed(terms_raw: str) -> dict[str, Any]:
    """Everything new about a set of terms: entities (countries, chokepoints, commodities…) and keywords."""
    terms = [t.strip() for t in terms_raw.replace(";", ",").split(",") if t.strip()]
    if not terms:
        raise ValueError("A case needs terms to follow, e.g. Taiwan, TSMC, chips")
    entities = {e.id for t in terms if (e := ent.find(t))}
    keywords = [t.lower() for t in terms if not ent.find(t)]
    events, _ = world.feed()
    watch = ent.watch_set(entities) if entities else set()
    hits = [e for e in events if (watch & set(e.entities)) or any(k in e.title.lower() for k in keywords)][:60]
    news: list[tuple[float, str, str, str | None]] = []
    for term in terms[:3]:
        for n in _yahoo_news(term):
            news.append((n.get("providerPublishTime") or 0, n["title"], n.get("publisher") or "", n.get("link")))
    for i in crypto_news.headlines()[0]:
        text = f"{i['title']} {i['summary']}".lower()
        if any(t.lower() in text for t in terms):
            news.append((i["time"] or 0, i["title"], i["publisher"], i["link"]))
    seen: set[str] = set()
    news = [n for n in sorted(news, key=lambda n: -n[0]) if not (n[1] in seen or seen.add(n[1]))][:40]
    return document("Case feed", [
        kv("Following", [("Entities", ", ".join(ent.get(i).name for i in sorted(entities)) or "—", "text"),
                         ("Keywords", ", ".join(keywords) or "—", "text"), ("Events now", len(hits), "int")]),
        map_block("map", None, _map_points(hits)),
        table("events", "World events", EVENT_COLUMNS, [_event_row(e) for e in hits]),
        table("news", "Headlines", [column("t", "Time", "datetime"), column("title", "Headline"), column("src", "Source")],
              [row([t, title, src], url=url) for t, title, src, url in news]),
    ], SOURCE, refresh=300, layout="map")


# MARK: EXPO — where the portfolio is exposed, and what is happening there

def _last_price(typed: str) -> float | None:
    try:
        sec = securities.resolve(typed)
        q = binance.quote(sec.symbol) if sec.provider == "binance" else yahoo.quote(sec.symbol)
        return q.get("last")
    except Exception:
        return None


def exposure(positions_raw: str) -> dict[str, Any]:
    """positions: 'AAPL US EQ|10;BTC CRYPTO|0.5' (quantities) or a plain watchlist 'AAPL US EQ;NVDA US EQ' (equal weight)."""
    holdings: list[tuple[str, float]] = []
    for item in [p for p in positions_raw.split(";") if p.strip()]:
        typed, _, qty = item.partition("|")
        holdings.append((typed.strip().upper(), float(qty) if qty else 0.0))
    if not holdings:
        raise ValueError("No positions or watchlist to analyse. Add positions with <security> PORT ADD <qty>.")
    weighted = any(q for _, q in holdings)
    values = {t: (q * (_last_price(t) or 0)) if weighted else 1.0 for t, q in holdings}
    total = sum(values.values()) or 1.0

    by_entity: dict[str, dict[str, Any]] = {}
    unmapped = []
    for typed, value in values.items():
        try:
            sec = securities.resolve(typed)
        except ValueError:
            continue
        profile = views.info(sec.yahoo_symbol) if sec.asset_class in (None, "EQ", "ETF") else {}
        parts = ent.exposure(sec.typed, profile)
        if not parts:
            unmapped.append(typed)
        for id, w, why in parts:
            slot = by_entity.setdefault(id, {"weight": 0.0, "holdings": []})
            slot["weight"] += value / total * w
            slot["holdings"].append(f"{typed.split()[0]} ({why})")

    events, failed = world.feed()
    ranked = sorted(by_entity.items(), key=lambda kv: -kv[1]["weight"])
    rows, risks, points = [], [], []
    for id, slot in ranked:
        e = ent.get(id)
        related = [ev for ev in events if ent.watch_set({id}) & set(ev.entities)]
        major = [ev for ev in related if ev.severity >= 2]
        rows.append(row([e.name if e else id, slot["weight"] * 100, e.kind if e else "", ", ".join(slot["holdings"][:4]),
                         len(related), major[0].title if major else ""], cmd=f"LINK {id}"))
        for ev in major[:5]:
            risks.append((slot["weight"], ev, e.name if e else id))
        if e and e.lat is not None:
            points.append({"lat": e.lat, "lon": e.lon, "label": f"{e.name}: {slot['weight'] * 100:.0f}% of portfolio",
                           "detail": f"{len(related)} events", "kind": "focus",
                           "severity": 3 if slot["weight"] > 0.25 else 2 if slot["weight"] > 0.1 else 1, "cmd": f"LINK {id}"})
    risks.sort(key=lambda r: (-r[1].severity, -r[0]))
    seen: set[str] = set()
    risk_rows = [row([ev.time, "●" * ev.severity, name, f"{w * 100:.0f}%", ev.title], url=ev.url, cmd=f"LINK {ev.entities[0]}")
                 for w, ev, name in risks if not (ev.id in seen or seen.add(ev.id))][:25]
    top = ranked[:3]
    notes = ["Weights: position value × each holding's exposure split (curated for large caps, else HQ country and industry)."
             + ("" if weighted else " No quantities: watchlist names are equally weighted.")]
    if unmapped:
        notes.append(f"No known world exposure for: {', '.join(unmapped)}.")
    if failed:
        notes.append(f"Event sources unavailable: {', '.join(failed)}.")
    return document("Portfolio world exposure", [
        kv("Summary", [("Holdings", len(holdings), "int"),
                       *[(f"#{i + 1} " + (ent.get(id).name if ent.get(id) else id), slot["weight"] * 100, "percent")
                         for i, (id, slot) in enumerate(top)],
                       ("Active risks (●● and up)", len(risk_rows), "int")]),
        bars("weights", "Exposure by entity (% of portfolio)",
             [{"label": ent.get(id).name if ent.get(id) else id, "value": slot["weight"] * 100, "cmd": f"LINK {id}"}
              for id, slot in ranked[:14]], kind="percent"),
        map_block("map", "Where the portfolio is exposed (white) and what is happening there",
                  points + _map_points([r[1] for r in risks])),
        table("risks", "Risks on your exposures right now", [column("t", "Time", "datetime"), column("sev", "Sev"),
                                                             column("ent", "Exposure"), column("w", "Weight"),
                                                             column("ev", "Event")], risk_rows),
        table("exposure", "Exposure detail", [column("ent", "Entity"), column("w", "Weight", "percent"), column("k", "Type"),
                                              column("h", "Through"), column("n", "Events"), column("top", "Most notable")], rows),
    ], SOURCE, notes=notes, refresh=300)
