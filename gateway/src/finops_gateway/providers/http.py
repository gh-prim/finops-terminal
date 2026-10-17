"""Minimal blocking JSON-over-HTTP helper (run it in a thread)."""

from __future__ import annotations

import gzip
import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class HTTPError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def get_json(url: str, params: dict[str, Any] | None = None, headers: dict[str, str] | None = None,
             timeout: float = 30) -> Any:
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Accept-Encoding": "gzip", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
            if response.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:300].decode("utf-8", "replace")
        raise HTTPError(exc.code, f"HTTP {exc.code} from {urllib.parse.urlparse(url).netloc}: {detail}") from None
    return json.loads(body)
