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
             notes: list[str] | None = None, refresh: float | None = None) -> dict[str, Any]:
    """`refresh`: seconds after which the app silently reloads the screen (live screens)."""
    return {
        "title": title,
        "subtitle": subtitle,
        # Drop empty tables and key/value cards (e.g. valuation fields don't exist for an index).
        "blocks": [b for b in blocks if not (b.get("type") == "table" and not b["rows"])
                   and not (b.get("type") == "kv" and not b["items"])],
        "source": source,
        "notes": notes or [],
        "asOf": time.time(),
        "refresh": refresh,
    }


# MARK: Visual blocks (rendered natively by the app)


def treemap(id: str, title: str | None, groups: list[dict[str, Any]], kind: str = "pctchange") -> dict[str, Any]:
    """groups: [{"label", "items": [{"label", "detail", "weight", "value", "cmd"}]}]; area = weight, colour = value."""
    return {"type": "treemap", "id": id, "title": title, "kind": kind, "groups": groups}


def matrix(id: str, title: str | None, rows: list[str], cols: list[str], values: list[list[Any]],
           kind: str = "number", scale: str = "diverging", center: float = 0.0,
           row_cmds: list[str | None] | None = None) -> dict[str, Any]:
    """Heat-coloured grid. scale: diverging (red/green around `center`) or correlation (-1…1)."""
    return {"type": "matrix", "id": id, "title": title, "rows": rows, "cols": cols,
            "values": [[cell(v) for v in r] for r in values], "kind": kind, "scale": scale, "center": center,
            "rowCmds": row_cmds}


def scatter(id: str, title: str | None, x_label: str, y_label: str, points: list[dict[str, Any]],
            x_kind: str = "number", y_kind: str = "number") -> dict[str, Any]:
    """points: [{"label", "x", "y", "size"?, "highlight"?, "cmd"?}]"""
    return {"type": "scatter", "id": id, "title": title, "xLabel": x_label, "yLabel": y_label,
            "xKind": x_kind, "yKind": y_kind,
            "points": [{**p, "x": cell(p["x"]), "y": cell(p["y"]), "size": cell(p.get("size"))} for p in points
                       if cell(p.get("x")) is not None and cell(p.get("y")) is not None]}


def graph(id: str, title: str | None, center: dict[str, Any], groups: list[dict[str, Any]]) -> dict[str, Any]:
    """Hub-and-spoke relationship graph. groups: [{"title", "side": left|right|bottom, "nodes": [{"label","detail","value","cmd"}]}]"""
    return {"type": "graph", "id": id, "title": title, "center": center, "groups": groups}


def bars(id: str, title: str | None, items: list[dict[str, Any]], kind: str = "number") -> dict[str, Any]:
    """Horizontal bars: [{"label", "value", "cmd"?}]"""
    return {"type": "bars", "id": id, "title": title, "kind": kind,
            "items": [{**i, "value": cell(i["value"])} for i in items if cell(i.get("value")) is not None]}


def series(id: str, title: str | None, lines: list[dict[str, Any]], kind: str = "number") -> dict[str, Any]:
    """Line chart: [{"label", "points": [[t, v], …]}]"""
    return {"type": "series", "id": id, "title": title, "kind": kind,
            "lines": [{"label": l["label"], "points": [[cell(t), cell(v)] for t, v in l["points"] if cell(v) is not None]}
                      for l in lines]}


def donut(id: str, title: str | None, items: list[dict[str, Any]], kind: str = "percent") -> dict[str, Any]:
    return {"type": "donut", "id": id, "title": title, "kind": kind,
            "items": [{**i, "value": cell(i["value"])} for i in items if cell(i.get("value"))]}


def sparkgrid(id: str, title: str | None, items: list[dict[str, Any]]) -> dict[str, Any]:
    """Small multiples: [{"label", "detail", "change", "points": [v…], "cmd"}]"""
    return {"type": "sparkgrid", "id": id, "title": title,
            "items": [{**i, "change": cell(i.get("change")), "points": [cell(v) for v in i["points"] if cell(v) is not None]}
                      for i in items if i.get("points")]}


def map_block(id: str, title: str | None, points: list[dict[str, Any]]) -> dict[str, Any]:
    """World map: points [{"lat", "lon", "label", "detail"?, "kind", "severity" 1-3, "cmd"?, "url"?}]."""
    return {"type": "map", "id": id, "title": title,
            "points": [{**p, "lat": cell(p["lat"]), "lon": cell(p["lon"])} for p in points
                       if cell(p.get("lat")) is not None and cell(p.get("lon")) is not None]}
