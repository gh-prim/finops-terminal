"""News sentiment read by Claude.

Each headline gets a score from −1 (clearly bad for the subject's price) to +1 (clearly good),
a tone, an expected impact and a one-line reason; the set gets an overall read. One request per
set of headlines, cached, so reopening a news screen doesn't re-bill. Without an Anthropic API key
callers fall back to the word lexicon.
"""

from __future__ import annotations

import json
import logging
import threading
from typing import Any

import anthropic

from ..cache import ttl_cache
from ..config import settings
from ..documents import column

log = logging.getLogger(__name__)
MODEL = "claude-sonnet-5-5"  # user choice (same as WHY)
MAX_HEADLINES = 40

SYSTEM = """You read financial news headlines for a trader's terminal.
For each numbered headline, judge its likely effect on the price of the subject named by the user
(a security, an asset class or the market as a whole):
- score: from -1.0 (clearly negative for the price) to +1.0 (clearly positive); 0 when neutral,
  irrelevant to the subject, or a generic explainer/listicle.
- tone: "bullish", "bearish" or "neutral", consistent with the score.
- impact: "high" for news that can move the price on its own (earnings, guidance, regulation,
  M&A, macro surprises, hacks), "medium" for relevant but incremental news, "low" otherwise.
- why: at most 12 words, the reason in plain language.
Judge from the headline only; do not invent facts. Clickbait ("3 stocks to buy now") is neutral/low.
Then give the overall read of the whole set: an average-like score and a summary of at most
40 words naming the main themes. No investment advice."""

SCHEMA = {
    "type": "object",
    "properties": {
        "items": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "n": {"type": "integer"},
                "score": {"type": "number"},
                "tone": {"type": "string", "enum": ["bullish", "bearish", "neutral"]},
                "impact": {"type": "string", "enum": ["high", "medium", "low"]},
                "why": {"type": "string"},
            },
            "required": ["n", "score", "tone", "impact", "why"],
            "additionalProperties": False,
        }},
        "overall": {
            "type": "object",
            "properties": {"score": {"type": "number"}, "summary": {"type": "string"}},
            "required": ["score", "summary"],
            "additionalProperties": False,
        },
    },
    "required": ["items", "overall"],
    "additionalProperties": False,
}

_lock = threading.Lock()  # one scoring request at a time (keeps the API bill and rate predictable)


def available() -> bool:
    return bool(settings.anthropic_api_key)


@ttl_cache(1800, maxsize=256)
def score(subject: str, titles: tuple[str, ...]) -> dict[str, Any]:
    """{"items": {title: {score, tone, impact, why}}, "overall": {score, summary}} or {"error": msg}."""
    if not settings.anthropic_api_key:
        return {"error": "Add an Anthropic API key in Settings for Claude's sentiment read."}
    titles = titles[:MAX_HEADLINES]
    listing = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(titles))
    client = anthropic.Anthropic(api_key=settings.anthropic_api_key, timeout=90.0)
    try:
        with _lock:
            response = client.beta.messages.create(
                model=MODEL,
                max_tokens=16000,
                output_config={"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                system=SYSTEM,
                messages=[{"role": "user", "content": f"Subject: {subject}\n\nHeadlines:\n{listing}"}],
            )
    except anthropic.AuthenticationError:
        return {"error": "The Anthropic API key was rejected. Check it in Settings."}
    except anthropic.RateLimitError:
        return {"error": "Claude is rate-limited right now; lexicon scores shown instead."}
    except anthropic.APIStatusError as exc:
        log.warning("news sentiment failed: %s", exc)
        return {"error": f"Claude returned an error ({exc.status_code}); lexicon scores shown instead."}
    except anthropic.APIConnectionError:
        return {"error": "Couldn't reach the Claude API; lexicon scores shown instead."}
    if response.stop_reason in ("refusal", "max_tokens"):
        return {"error": "Claude didn't return a usable read; lexicon scores shown instead."}
    try:
        data = json.loads(next(b.text for b in response.content if b.type == "text"))
    except (StopIteration, json.JSONDecodeError):
        return {"error": "Claude's answer couldn't be read; lexicon scores shown instead."}
    items = {}
    for it in data.get("items", []):
        n = it.get("n")
        if isinstance(n, int) and 1 <= n <= len(titles):
            items[titles[n - 1]] = {**it, "score": max(-1.0, min(1.0, float(it.get("score") or 0)))}
    return {"items": items, "overall": data.get("overall") or {}}


def annotate(doc: dict[str, Any], subject: str) -> dict[str, Any]:
    """Add Claude's tone to a news document's headline table (columns: time, title, source)."""
    tables = [b for b in doc.get("blocks", []) if b.get("type") == "table"]
    if not tables or not available():
        return doc
    news = tables[0]
    title_col = next((i for i, c in enumerate(news["columns"]) if c["id"] == "title"), None)
    if title_col is None or not news["rows"]:
        return doc
    read = score(subject, tuple(r["cells"][title_col] or "" for r in news["rows"]))
    if "error" in read:
        return {**doc, "notes": [*doc.get("notes", []), read["error"]]}
    columns = list(news["columns"])
    columns[1:1] = [column("sent", "Claude", "score"), column("impact", "Impact")]
    rows = []
    for r in news["rows"]:
        s = read["items"].get(r["cells"][title_col] or "") or {}
        cells = list(r["cells"])
        cells[1:1] = [s.get("score"), s.get("impact") or ""]
        rows.append({**r, "cells": cells})
    blocks = [({**b, "columns": columns, "rows": rows} if b is news else b) for b in doc["blocks"]]
    overall = read.get("overall") or {}
    notes = [f"Claude's read ({overall.get('score', 0):+.2f}): {overall.get('summary', '')}"] if overall.get("summary") else []
    return {**doc, "blocks": blocks, "notes": [*notes, *doc.get("notes", [])]}
