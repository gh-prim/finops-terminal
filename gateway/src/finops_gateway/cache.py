"""Small in-memory TTL cache for blocking provider calls (stale values cover provider errors)."""

from __future__ import annotations

import functools
import threading
import time
from collections.abc import Callable
from typing import Any, ParamSpec, TypeVar

P = ParamSpec("P")
R = TypeVar("R")


def ttl_cache(seconds: float, maxsize: int = 256) -> Callable[[Callable[P, R]], Callable[P, R]]:
    def decorator(fn: Callable[P, R]) -> Callable[P, R]:
        store: dict[Any, tuple[float, R]] = {}
        lock = threading.Lock()

        @functools.wraps(fn)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            key = (args, tuple(sorted(kwargs.items())))
            now = time.monotonic()
            with lock:
                hit = store.get(key)
                if hit and now - hit[0] < seconds:
                    return hit[1]
            try:
                value = fn(*args, **kwargs)
            except Exception:
                # A provider hiccup (rate limit, timeout): serve the last good value for up to a day.
                if hit and now - hit[0] < 86400:
                    return hit[1]
                raise
            with lock:
                if len(store) >= maxsize:
                    store.pop(next(iter(store)))
                store[key] = (now, value)
            return value

        wrapper.cache_clear = store.clear  # type: ignore[attr-defined]
        return wrapper

    return decorator
