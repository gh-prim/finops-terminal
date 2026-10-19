"""One guard in front of every Yahoo request yfinance makes.

Yahoo rate-limits per IP (here: the home connection the backend and the Mac share).
  - throttle: at most RATE requests per second across all threads
  - cooldown: after a 429, stop asking for 1 min, then 2, 4… up to 15 (reset after a success),
    and fail fast meanwhile so callers fall back to cached data instead of piling on.
"""

from __future__ import annotations

import threading
import time

from yfinance import data as yf_data
from yfinance.exceptions import YFRateLimitError

RATE = 6.0                 # requests per second (heatmaps fetch ~120 prices at once)
MIN_COOLDOWN, MAX_COOLDOWN = 60.0, 900.0


class _Guard:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.next_slot = 0.0
        self.blocked_until = 0.0
        self.cooldown = MIN_COOLDOWN

    def before(self) -> None:
        with self.lock:
            now = time.monotonic()
            if now < self.blocked_until:
                raise YFRateLimitError()
            wait = max(0.0, self.next_slot - now)
            self.next_slot = max(now, self.next_slot) + 1 / RATE
        if wait:
            time.sleep(wait)

    def limited(self) -> None:
        with self.lock:
            self.blocked_until = time.monotonic() + self.cooldown
            self.cooldown = min(self.cooldown * 2, MAX_COOLDOWN)

    def ok(self) -> None:
        with self.lock:
            self.cooldown = MIN_COOLDOWN

    def seconds_left(self) -> float:
        return max(0.0, self.blocked_until - time.monotonic())


guard = _Guard()


def install() -> None:
    original = yf_data.YfData._make_request
    if getattr(original, "_guarded", False):
        return

    def guarded(self, url, request_method, *args, **kwargs):  # type: ignore[no-untyped-def]
        guard.before()
        try:
            response = original(self, url, request_method, *args, **kwargs)
        except YFRateLimitError:
            guard.limited()
            raise
        if getattr(response, "status_code", 200) == 429:
            guard.limited()
        else:
            guard.ok()
        return response

    guarded._guarded = True  # type: ignore[attr-defined]
    yf_data.YfData._make_request = guarded


def message() -> str:
    left = guard.seconds_left()
    return (f"Yahoo Finance is rate-limiting this connection; retrying in {left / 60:.0f} min. Cached data is shown where available."
            if left else "Yahoo Finance is rate-limiting this connection; try again in a minute.")
