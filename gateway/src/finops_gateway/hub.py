"""Subscription hub: one feed per symbol (Yahoo poller or Binance stream), fanned out to every subscriber."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from .providers import binance_stream, yahoo

log = logging.getLogger(__name__)

Sink = Callable[[str, dict[str, Any]], Awaitable[None]]  # (kind, payload)


class Hub:
    def __init__(self, poll_seconds: float = 5.0) -> None:
        self.poll_seconds = poll_seconds
        self._subscribers: dict[str, set[Sink]] = {}
        self._pollers: dict[str, asyncio.Task[None]] = {}

    def subscribe(self, symbol: str, sink: Sink, provider: str = "yahoo") -> str:
        """Returns the feed key to pass to `unsubscribe`."""
        key = symbol if provider == "yahoo" else f"{provider}:{symbol}"
        self._subscribers.setdefault(key, set()).add(sink)
        if key not in self._pollers:
            if provider == "binance":
                async def emit(kind: str, payload: dict[str, Any]) -> None:
                    await self._broadcast(key, kind, payload)
                self._pollers[key] = asyncio.create_task(binance_stream.stream(symbol, emit))
            else:
                self._pollers[key] = asyncio.create_task(self._poll(symbol))
        return key

    def unsubscribe(self, symbol: str, sink: Sink) -> None:
        sinks = self._subscribers.get(symbol)
        if not sinks:
            return
        sinks.discard(sink)
        if not sinks:
            del self._subscribers[symbol]
            self._pollers.pop(symbol).cancel()

    async def _broadcast(self, symbol: str, kind: str, payload: dict[str, Any]) -> None:
        for sink in list(self._subscribers.get(symbol, ())):
            try:
                await sink(kind, payload)
            except Exception:
                log.exception("subscriber failed for %s", symbol)

    async def _poll(self, symbol: str) -> None:
        stale = False
        while True:
            try:
                q = await asyncio.to_thread(yahoo.quote, symbol)
                if stale:
                    await self._broadcast(symbol, "subStatus", {"status": "started"})
                    stale = False
                await self._broadcast(symbol, "tick", q)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                if not stale:
                    await self._broadcast(symbol, "subStatus", {"status": "stale", "reason": str(exc)})
                    stale = True
            await asyncio.sleep(self.poll_seconds)
