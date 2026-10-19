"""WHY: why did this security move?

1. Measure the move: last session's return and volume against their recent spread (z-scores),
   and list the unusual sessions of the last three months.
2. Gather what happened around it: the security's headlines, world events on its exposures,
   US macro releases, and how the market and related assets moved the same session.
3. Ask Claude for a short, sourced synthesis (when an Anthropic API key is configured).
"""

from __future__ import annotations

import logging
import math
import statistics
import time
from typing import Any

import anthropic

from .. import securities
from ..cache import ttl_cache
from ..config import settings
from ..documents import bars, column, document, kv, row, table, text
from ..providers import binance, views, yahoo
from . import entities as ent
from . import markers as mk
from . import world

log = logging.getLogger(__name__)
MODEL = "claude-sonnet-5-5"  # user choice: Sonnet 5.5 is plenty for a short synthesis
CONTEXT = ["SPX IDX", "NDX IDX", "VIX IDX", "DXY IDX", "CL1 CMD", "GC1 CMD", "TNX IDX", "BTC CRYPTO"]

SYSTEM = """You are the market analyst inside a trading terminal. A trader asks why a security moved.
You get the measured move and the evidence gathered around it: headlines, world events linked to the
security's exposures, macro releases, and same-session moves of the market and related assets.

Write a short explanation:
- First line: the most likely driver, in one sentence.
- Then 2 to 4 bullets with the supporting evidence, each citing its item number like [N3] or [W2].
- Separate what the evidence shows from what you infer, and say so plainly when the evidence does
  not explain the move (e.g. it tracks the market, or nothing specific was found).
- Last line: "Confidence: low | medium | high" with a few words why.
Use only the evidence given. No investment advice, no price targets. Under 170 words."""


def _history(sec: securities.Security) -> list[dict[str, Any]]:
    source = binance if sec.provider == "binance" else yahoo
    return source.history(sec.symbol, "1Y", "1DAY")["bars"]


def _returns(closes: list[float]) -> list[float]:
    return [(b / a - 1) * 100 for a, b in zip(closes, closes[1:]) if a]


def _zscore(value: float, sample: list[float]) -> float | None:
    if len(sample) < 10:
        return None
    sd = statistics.pstdev(sample)
    return (value - statistics.fmean(sample)) / sd if sd else None


def _session_move(typed: str) -> float | None:
    """Last session's % move of another security (for context)."""
    try:
        sec = securities.resolve(typed)
        b = (binance if sec.provider == "binance" else yahoo).history(sec.symbol, "1M", "1DAY")["bars"]
        return (b[-1]["c"] / b[-2]["c"] - 1) * 100 if len(b) >= 2 else None
    except Exception:
        return None


def why(typed: str) -> dict[str, Any]:
    sec = securities.resolve(typed)
    hist = _history(sec)
    if len(hist) < 30:
        raise LookupError(f"not enough history for {sec.typed}")
    closes = [b["c"] for b in hist]
    rets = _returns(closes)
    vols = [b.get("v") or 0 for b in hist]
    move = rets[-1]
    z = _zscore(move, rets[-61:-1])
    vol_ratio = vols[-1] / statistics.fmean(vols[-21:-1]) if statistics.fmean(vols[-21:-1] or [0]) else None
    session_start = hist[-2]["t"]          # previous close -> now
    unusual = []
    for i in range(max(1, len(rets) - 63), len(rets)):
        zi = _zscore(rets[i], rets[max(0, i - 60):i])
        if zi is not None and abs(zi) >= 2:
            unusual.append((hist[i + 1]["t"], rets[i], zi))

    # Evidence.
    profile = views.info(sec.yahoo_symbol) if sec.asset_class in (None, "EQ", "ETF") else {}
    exposure = ent.exposure(sec.typed, profile)
    watch = ent.watch_set({id for id, _, _ in exposure})
    window_start = session_start - 86400   # a day before the session, news often leads
    marks = mk.markers(sec.typed, "1M")["markers"]
    news = [m for m in marks if m["kind"] == "news" and m["t"] >= window_start][-12:]
    macro = [m for m in marks if m["kind"] == "macro" and m["t"] >= window_start - 86400]
    events = [e for e in world.for_entities(watch, 40) if e.time >= window_start - 86400][:10] if watch else []
    related = list(dict.fromkeys([a.security for id in watch if (e := ent.get(id)) for a in e.assets
                                  if a.security != sec.typed]))[:8]
    context_moves = {t: _session_move(t) for t in CONTEXT if t != sec.typed}
    related_moves = {t: _session_move(t) for t in related}

    evidence = _evidence_text(sec, move, z, vol_ratio, news, events, macro, context_moves, related_moves, exposure)
    analysis, note = _synthesis(sec.typed, round(hist[-1]["t"]), evidence)

    name = profile.get("shortName") or binance.name(sec.symbol) if sec.provider == "binance" else profile.get("shortName")
    blocks: list[dict[str, Any]] = [
        kv("The move", [("Last", closes[-1], "price"), ("Session change", move, "pctchange"),
                        ("vs normal (z-score)", z, "number"), ("Volume vs 20-day avg", vol_ratio, "number"),
                        ("Session", hist[-1]["t"], "date")]),
        kv("Verdict", [("Unusual move", "yes" if z is not None and abs(z) >= 2 else "no — within its normal range", "text"),
                       ("Market (SPX) same session", context_moves.get("SPX IDX"), "pctchange"),
                       ("Moves alone", "yes" if z and abs(move - (context_moves.get("SPX IDX") or 0)) > abs(move) * 0.5 else
                        "mostly with the market", "text")]),
        text("Analysis" + (" (Claude)" if analysis else ""), analysis or note),
        table("context", "Market the same session", [column("sec", "Asset"), column("chg", "Change", "pctchange")],
              [row([t, v], cmd=f"{t} CHART") for t, v in context_moves.items() if v is not None]),
        table("related", "Linked assets the same session", [column("sec", "Asset"), column("chg", "Change", "pctchange")],
              [row([t, v], cmd=f"{t} WHY") for t, v in related_moves.items() if v is not None]),
        table("news", "Headlines around the move", [column("id", "#"), column("t", "Time", "datetime"),
                                                    column("title", "Headline"), column("src", "Source")],
              [row([f"N{i + 1}", m["t"], m["title"], m["detail"]], url=m["url"]) for i, m in enumerate(news)]),
        table("events", "World events on its exposures", [column("id", "#"), column("t", "Time", "datetime"),
                                                           column("title", "Event"), column("place", "Where")],
              [row([f"W{i + 1}", e.time, e.title, e.place], url=e.url, cmd=None if e.url else f"LINK {e.entities[0]}")
               for i, e in enumerate(events)]),
        table("macro", "Macro releases", [column("id", "#"), column("t", "Time", "datetime"), column("ev", "Release"),
                                          column("d", "Result")],
              [row([f"M{i + 1}", m["t"], m["title"], m["detail"]]) for i, m in enumerate(macro)]),
        bars("unusual", "Unusual sessions, last 3 months (z-score of the daily move)",
             [{"label": time.strftime("%d %b", time.gmtime(t)), "value": zi} for t, r, zi in unusual[-12:]]),
    ]
    return document(f"Why did {sec.typed} move?", blocks,
                    "Prices: Yahoo/Binance · news: Yahoo, crypto RSS · events: GDELT, GDACS, USGS, PortWatch · synthesis: Claude Sonnet 5.5",
                    subtitle=name, notes=["Evidence is gathered automatically; the synthesis only uses what is listed here."])


def _evidence_text(sec: securities.Security, move: float, z: float | None, vol_ratio: float | None,
                   news: list[dict[str, Any]], events: list[world.Event], macro: list[dict[str, Any]],
                   context: dict[str, float | None], related: dict[str, float | None],
                   exposure: list[tuple[str, float, str]]) -> str:
    def pct(v: float | None) -> str:
        return "n/a" if v is None or math.isnan(v) else f"{v:+.2f}%"

    lines = [f"Security: {sec.typed}", f"Session move: {pct(move)}" + (f", z-score {z:+.1f} vs the last 60 sessions" if z else "")
             + (f", volume {vol_ratio:.1f}x its 20-day average" if vol_ratio else ""),
             "Exposures: " + "; ".join(f"{(ent.get(i).name if ent.get(i) else i)} ({w * 100:.0f}%, {why})" for i, w, why in exposure),
             "", "Market the same session: " + ", ".join(f"{t} {pct(v)}" for t, v in context.items() if v is not None),
             "Linked assets the same session: " + (", ".join(f"{t} {pct(v)}" for t, v in related.items() if v is not None) or "none"),
             "", "Headlines:"]
    lines += [f"[N{i + 1}] {time.strftime('%d %b %H:%M', time.gmtime(m['t']))} UTC · {m['title']} ({m['detail'] or ''})"
              for i, m in enumerate(news)] or ["none found"]
    lines += ["", "World events on its exposures:"]
    lines += [f"[W{i + 1}] {time.strftime('%d %b %H:%M', time.gmtime(e.time))} UTC · {e.title} · {e.detail or ''}"
              for i, e in enumerate(events)] or ["none found"]
    lines += ["", "Macro releases:"]
    lines += [f"[M{i + 1}] {m['title']}: {m['detail']}" for i, m in enumerate(macro)] or ["none"]
    return "\n".join(lines)


@ttl_cache(1800, maxsize=128)
def _synthesis(typed: str, session: int, evidence: str) -> tuple[str | None, str]:
    """(analysis, note). Cached per security and session, so re-opening WHY doesn't re-bill."""
    if not settings.anthropic_api_key:
        return None, "Add an Anthropic API key in Settings to get a written analysis. The evidence below is complete without it."
    client = anthropic.Anthropic(api_key=settings.anthropic_api_key, timeout=90.0)
    try:
        response = client.beta.messages.create(
            model=MODEL,
            max_tokens=16000,
            output_config={"effort": "medium"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            system=SYSTEM,
            messages=[{"role": "user", "content": f"Why did {typed} move?\n\n{evidence}"}],
        )
    except anthropic.AuthenticationError:
        return None, "The Anthropic API key was rejected. Check it in Settings."
    except anthropic.RateLimitError:
        return None, "Claude is rate-limited right now; try again in a minute."
    except anthropic.APIStatusError as exc:
        log.warning("WHY synthesis failed: %s", exc)
        return None, f"Claude returned an error ({exc.status_code})."
    except anthropic.APIConnectionError:
        return None, "Couldn't reach the Claude API."
    if response.stop_reason == "refusal":
        return None, "Claude declined to write an analysis for this one."
    words = "".join(b.text for b in response.content if b.type == "text").strip()
    return (words or None), ("" if words else "Claude returned no text.")
