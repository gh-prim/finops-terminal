"""READ: fetch a news article and extract its readable text (trafilatura).

The gateway fetches on behalf of the app, so only public http(s) hosts are
allowed: every hop (including redirects) must resolve to global addresses, which
keeps a paired device from probing the backend's own network.
"""

from __future__ import annotations

import ipaddress
import socket
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import trafilatura

from ..cache import ttl_cache

USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")
MAX_BYTES = 4_000_000
MIN_READABLE = 600  # shorter extractions are teasers or paywalls: the app shows the web page instead


def check_public(url: str) -> None:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("only http(s) links can be read")
    try:
        infos = socket.getaddrinfo(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80))
    except socket.gaierror:
        raise LookupError(f"cannot resolve {parts.hostname}") from None
    for info in infos:
        address = ipaddress.ip_address(info[4][0].split("%")[0])
        if not address.is_global:
            raise ValueError(f"{parts.hostname} is not a public host")


class _PublicRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        check_public(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_PublicRedirects)


def fetch(url: str) -> tuple[str, bytes]:
    check_public(url)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.8"})
    try:
        with _opener.open(request, timeout=15) as response:
            return response.geturl(), response.read(MAX_BYTES)
    except urllib.error.HTTPError as exc:
        raise LookupError(f"{urllib.parse.urlsplit(url).hostname} refused the request (HTTP {exc.code})") from None


@ttl_cache(1800, maxsize=64)
def read(url: str) -> dict[str, Any]:
    final, body = fetch(url)
    doc = trafilatura.bare_extraction(body, url=final, with_metadata=True, include_comments=False,
                                      include_tables=False, favor_precision=True)
    text = (doc.text if doc else None) or ""
    paragraphs = [p.strip() for p in text.split("\n") if p.strip()]
    return {
        "url": url,
        "finalUrl": final,
        "title": doc.title if doc else None,
        "author": doc.author if doc else None,
        "site": (doc.sitename if doc else None) or urllib.parse.urlsplit(final).hostname,
        "date": doc.date if doc else None,
        "paragraphs": paragraphs,
        "readable": len(text) >= MIN_READABLE,
    }
