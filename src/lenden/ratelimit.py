"""Small in-memory sliding-window rate limiter (per process).

Good enough for one instance on Render. With several instances, move the counters to Redis
(Render Key Value) behind the same interface.
"""
from __future__ import annotations

import threading
import time
from collections import defaultdict, deque

from .errors import RateLimited


class Limiter:
    def __init__(self):
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = threading.Lock()

    def _trim(self, q: deque, window: float, now: float) -> None:
        while q and q[0] <= now - window:
            q.popleft()

    def check(self, key: str, limit: int, window: float, message: str = "Too many attempts. Please wait and try again.",
              code: str = "RATE_LIMITED") -> None:
        """Raise RateLimited if `key` already has `limit` hits inside `window` seconds."""
        now = time.monotonic()
        with self._lock:
            q = self._hits[key]
            self._trim(q, window, now)
            if len(q) >= limit:
                retry = int(window - (now - q[0])) + 1
                raise RateLimited(message, code=code, fields={"retry_after_seconds": retry})

    def hit(self, key: str) -> None:
        with self._lock:
            self._hits[key].append(time.monotonic())

    def take(self, key: str, limit: int, window: float, message: str = "Too many requests. Please slow down.",
             code: str = "RATE_LIMITED") -> None:
        """check + hit in one step (for counting every request, not only failures)."""
        self.check(key, limit, window, message, code)
        self.hit(key)

    def reset(self, key: str | None = None) -> None:
        with self._lock:
            if key is None:
                self._hits.clear()
            else:
                self._hits.pop(key, None)


limiter = Limiter()
