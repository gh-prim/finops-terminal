"""Binance WebSocket market streams -> gateway quote ticks.

One connection per pair, combining the 24h ticker (stats, once a second) with
aggregated trades (every fill), so the last price moves with each trade. Ticks
are throttled to `min_interval` so a busy pair doesn't flood the apps.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

import websockets

from .binance import quote, quote_from_ticker

log = logging.getLogger(__name__)

STREAM_URL = "wss://stream.binance.com:9443/stream?streams={pair}@ticker/{pair}@aggTrade"

Emit = Callable[[str, dict[str, Any]], Awaitable[None]]  # (kind, payload)


def apply_trade(q: dict[str, Any], trade: dict[str, Any]) -> dict[str, Any]:
    """Move a quote's last price (and day range) to an aggregated trade."""
    price = float(trade["p"])
    out = {**q, "last": price, "asOf": trade["T"] / 1000}
    if q.get("previousClose"):
        out["change"] = price - q["previousClose"]
        out["changePct"] = out["change"] / q["previousClose"] * 100
    if q.get("dayHigh") is not None:
        out["dayHigh"] = max(q["dayHigh"], price)
    if q.get("dayLow") is not None:
        out["dayLow"] = min(q["dayLow"], price)
    return out


async def stream(pair: str, emit: Emit, min_interval: float = 0.25) -> None:
    """Run until cancelled, reconnecting with backoff (Binance drops sockets after 24 h)."""
    current: dict[str, Any] | None = None
    stale = False
    backoff = 1.0
    while True:
        try:
            # Seed with a REST snapshot so subscribers get a price immediately.
            current = await asyncio.to_thread(quote, pair)
            await emit("tick", current)
            async with websockets.connect(STREAM_URL.format(pair=pair.lower()), ping_interval=20,
                                          open_timeout=10) as ws:
                if stale:
                    await emit("subStatus", {"status": "started"})
                    stale = False
                backoff = 1.0
                last_emit = 0.0
                async for raw in ws:
                    msg = json.loads(raw)
                    data = msg.get("data", {})
                    match data.get("e"):
                        case "24hrTicker":
                            # The ticker's last price can lag the newest trade by up to a second.
                            fresher = current if current and current["asOf"] > data["E"] / 1000 else None
                            current = quote_from_ticker(data)
                            if fresher:
                                current = apply_trade(current, {"p": fresher["last"], "T": fresher["asOf"] * 1000})
                        case "aggTrade" if current:
                            current = apply_trade(current, data)
                        case _:
                            continue
                    now = time.monotonic()
                    if now - last_emit >= min_interval:
                        last_emit = now
                        await emit("tick", current)
        except asyncio.CancelledError:
            raise
        except LookupError as exc:
            await emit("subStatus", {"status": "stale", "reason": str(exc)})
            return  # unknown pair: retrying won't help
        except Exception as exc:
            log.warning("binance stream %s: %s", pair, exc)
            if not stale:
                await emit("subStatus", {"status": "stale", "reason": f"Binance stream: {exc}"})
                stale = True
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
