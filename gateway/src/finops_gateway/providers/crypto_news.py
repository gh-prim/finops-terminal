"""Crypto headlines merged from the publishers' public RSS feeds (no key needed)."""

from __future__ import annotations

import email.utils
import html
import re
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from ..cache import ttl_cache
from ..documents import choices, column, document, row, table
from .binance import NAMES

FEEDS = {
    "CoinDesk": "https://www.coindesk.com/arc/outboundfeeds/rss/",
    "Cointelegraph": "https://cointelegraph.com/rss",
    "Decrypt": "https://decrypt.co/feed",
    "The Block": "https://www.theblock.co/rss.xml",
}
SOURCE = "CoinDesk, Cointelegraph, Decrypt, The Block (RSS; headlines link to publishers)"
TAGS = re.compile(r"<[^>]+>")


def _text(item: ET.Element, tag: str) -> str:
    return html.unescape(TAGS.sub("", item.findtext(tag) or "")).strip()


def parse(publisher: str, body: bytes) -> list[dict[str, Any]]:
    out = []
    for item in ET.fromstring(body).iter("item"):
        title = _text(item, "title")
        if not title:
            continue
        try:
            published = email.utils.parsedate_to_datetime(item.findtext("pubDate") or "").timestamp()
        except (TypeError, ValueError):
            published = None
        out.append({
            "title": title,
            "link": (item.findtext("link") or "").strip() or None,
            "time": published,
            "publisher": publisher,
            "summary": _text(item, "description")[:400],
            "tags": [c.text.strip() for c in item.findall("category") if c.text],
        })
    return out


@ttl_cache(120, maxsize=8)
def _feed(publisher: str) -> list[dict[str, Any]]:
    request = urllib.request.Request(FEEDS[publisher], headers={"User-Agent": "Mozilla/5.0 finops-terminal"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return parse(publisher, response.read())


def headlines() -> tuple[list[dict[str, Any]], list[str]]:
    """All items, newest first, plus the publishers that failed."""
    def load(publisher: str) -> list[dict[str, Any]] | None:
        try:
            return _feed(publisher)
        except Exception:
            return None

    with ThreadPoolExecutor(max_workers=len(FEEDS)) as pool:
        results = dict(zip(FEEDS, pool.map(load, FEEDS)))
    seen: set[str] = set()
    items = []
    for item in sorted((i for r in results.values() if r for i in r), key=lambda i: -(i["time"] or 0)):
        key = item["title"].lower()
        if key not in seen:
            seen.add(key)
            items.append(item)
    return items, [p for p, r in results.items() if r is None]


def mentions(item: dict[str, Any], base: str) -> bool:
    """Ticker as a whole word (case-sensitive, so "OP" isn't "op-ed"), or the coin's name."""
    text = " ".join([item["title"], item["summary"], *item["tags"]])
    if re.search(rf"\b{re.escape(base)}\b", text):
        return True
    name = NAMES.get(base)
    return bool(name) and re.search(rf"\b{re.escape(name)}\b", text, re.IGNORECASE) is not None


def news(base: str | None = None, count: int = 50) -> dict[str, Any]:
    items, failed = headlines()
    notes = [f"Unavailable right now: {', '.join(failed)}."] if failed else []
    title = "Crypto news"
    if base:
        name = NAMES.get(base, base)
        matched = [i for i in items if mentions(i, base)]
        title = f"Crypto news — {name}"
        if not matched:
            notes.insert(0, f"No recent headline mentions {name}; showing all crypto headlines.")
        else:
            items = matched
    rows = [row([i["time"], i["title"], i["publisher"]], url=i["link"]) for i in items[:count]]
    blocks = [table("news", None, [column("time", "Time", "datetime"), column("title", "Headline"),
                                   column("source", "Source")], rows)]
    if base:
        blocks.insert(0, choices("scope", None, [(NAMES.get(base, base), f"{base} CRYPTO NEWS"),
                                                 ("All crypto", "NEWS CRYPTO")], NAMES.get(base, base)))
    return document(title, blocks, SOURCE, notes=notes or (["No headlines found."] if not rows else []))


def latest(count: int = 8) -> list[dict[str, Any]]:
    try:
        return headlines()[0][:count]
    except Exception:
        return []
