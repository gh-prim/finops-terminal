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
    """Yahoo symbols share ONE batch poll (one request per 50 symbols per cycle: Yahoo rate-limits per
    request, and a wall of TVs/iPads can follow dozens of symbols); Binance pairs stream individually."""

    def __init__(self, poll_seconds: float = 10.0) -> None:
        self.poll_seconds = poll_seconds
        self._subscribers: dict[str, set[Sink]] = {}
        self._pollers: dict[str, asyncio.Task[None]] = {}
        self._yahoo: set[str] = set()
        self._batch: asyncio.Task[None] | None = None
        self._stale = False

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
                self._yahoo.add(symbol)
                if self._batch is None or self._batch.done():
                    self._batch = asyncio.create_task(self._poll_batch())
                else:
                    asyncio.create_task(self._poll_once([symbol]))  # first price right away
        return key

    def unsubscribe(self, symbol: str, sink: Sink) -> None:
        sinks = self._subscribers.get(symbol)
        if not sinks:
            return
        sinks.discard(sink)
        if not sinks:
            del self._subscribers[symbol]
            if (task := self._pollers.pop(symbol, None)) is not None:
                task.cancel()
            self._yahoo.discard(symbol)

    async def _broadcast(self, symbol: str, kind: str, payload: dict[str, Any]) -> None:
        for sink in list(self._subscribers.get(symbol, ())):
            try:
                await sink(kind, payload)
            except Exception:
                log.exception("subscriber failed for %s", symbol)

    async def _poll_once(self, symbols: list[str]) -> None:
        try:
            quotes = await asyncio.to_thread(yahoo.quotes, symbols)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if not self._stale:
                self._stale = True
                for symbol in list(self._yahoo):
                    await self._broadcast(symbol, "subStatus", {"status": "stale", "reason": str(exc) or "Yahoo unavailable"})
            return
        if self._stale:
            self._stale = False
            for symbol in list(self._yahoo):
                await self._broadcast(symbol, "subStatus", {"status": "started"})
        for symbol, q in quotes.items():
            if symbol in self._yahoo:
                await self._broadcast(symbol, "tick", q)

    async def _poll_batch(self) -> None:
        while self._yahoo:
            await self._poll_once(sorted(self._yahoo))
            await asyncio.sleep(self.poll_seconds)
