"""Generic "document" responses rendered by the app's DocumentView.

A document is a list of blocks. Clickable things carry a `cmd` (a terminal
command string, run exactly as if typed) or a `url`, so every screen works the
same way from the mouse and from the command line.

Column/value kinds understood by the app:
  text, int, number, price, compact, percent (value already in %),
  pctchange / change (signed + colored), date / datetime (epoch seconds)
"""

from __future__ import annotations

import datetime as dt
import math
import time
from typing import Any

import pandas as pd


def cell(value: Any) -> Any:
    """Convert pandas/numpy/datetime values into JSON-safe scalars."""
    if value is None:
        return None
    if isinstance(value, pd.Timestamp):
        return None if pd.isna(value) else value.timestamp()
    if isinstance(value, dt.datetime):
        return value.timestamp()
    if isinstance(value, dt.date):
        return dt.datetime(value.year, value.month, value.day, tzinfo=dt.UTC).timestamp()
    if isinstance(value, bool):
        return value
    if hasattr(value, "item"):  # numpy scalar
        value = value.item()
    if isinstance(value, float):
        return None if math.isnan(value) or math.isinf(value) else value
    if isinstance(value, int | str):
        return value
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    return str(value)


def column(id: str, label: str, kind: str = "text") -> dict[str, str]:
    return {"id": id, "label": label, "kind": kind}


def row(cells: list[Any], cmd: str | None = None, url: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"cells": [cell(c) for c in cells]}
    if cmd:
        out["cmd"] = cmd
    if url:
        out["url"] = url
    return out


def table(id: str, title: str | None, columns: list[dict[str, str]], rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {"type": "table", "id": id, "title": title, "columns": columns, "rows": rows}


def kv(title: str | None, items: list[tuple[str, Any, str] | tuple[str, Any, str, str]]) -> dict[str, Any]:
    out = []
    for item in items:
        label, value, kind = item[0], cell(item[1]), item[2]
        if value is None:
            continue
        entry = {"label": label, "value": value, "kind": kind}
        if len(item) == 4:
            entry["url"] = item[3]
        out.append(entry)
    return {"type": "kv", "title": title, "items": out}


def text(title: str | None, body: str) -> dict[str, Any]:
    return {"type": "text", "title": title, "text": body}


def choices(id: str, title: str | None, items: list[tuple[str, str]], selected: str | None) -> dict[str, Any]:
    return {
        "type": "choices",
        "id": id,
        "title": title,
        "items": [{"label": label, "cmd": cmd} for label, cmd in items],
        "selected": selected,
    }


def document(title: str, blocks: list[dict[str, Any]], source: str, subtitle: str | None = None,
             notes: list[str] | None = None) -> dict[str, Any]:
    return {
        "title": title,
        "subtitle": subtitle,
        "blocks": [b for b in blocks if b.get("type") != "table" or b["rows"]],
        "source": source,
        "notes": notes or [],
        "asOf": time.time(),
    }
