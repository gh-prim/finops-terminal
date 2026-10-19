"""WebSocket server implementing the finops-terminal data protocol.

client -> gateway
  {"t": "request", "cid", "service": "refdata"|"history"|"lookup", "params": {...}}
  {"t": "subscribe", "cid", "security"}
  {"t": "unsubscribe", "cid"}

gateway -> client
  {"t": "response", "cid", "data"}
  {"t": "tick", "cid", "data"}
  {"t": "subStatus", "cid", "status", "reason"?}
  {"t": "error", "cid", "code", "message"}
"""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import logging
import secrets
from typing import Any

from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from . import securities
from .securities import split_pair
from .config import settings
from .devices import DeviceStore, PostgresDeviceStore
from .hub import Hub
from .providers import article, binance, crypto_news, edgar, fred, rwa, yahoo
from .providers import yahoo_research as research
from .providers import views
from yfinance.exceptions import YFRateLimitError

from .providers import yahoo_guard
from .providers.http import HTTPError
from .intel import markers as intel_markers
from .intel import exposure as intel_exposure
from .intel import rules as intel_rules
from .intel import study as intel_study
from .intel import why as intel_why
from .intel import screens as intel

log = logging.getLogger(__name__)


BACKEND_NAME = "finops-backend"
AUTH_TIMEOUT = 10


def create_app(token: str | None = None, hub: Hub | None = None, devices: DeviceStore | None = None,
               database_url: str | None = None) -> FastAPI:
    """`token`: single shared secret (the Mac's local sidecar).
    `devices` / `database_url`: per-device pairing (the shared backend)."""

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Provider calls run in threads and can block on slow upstreams (Yahoo, GDELT); the default
        # pool (cpu + 4 threads) is too small on the VM, and one stuck call would stall every screen.
        asyncio.get_running_loop().set_default_executor(ThreadPoolExecutor(max_workers=48, thread_name_prefix="provider"))
        if database_url and app.state.devices is None:
            app.state.devices = await PostgresDeviceStore.connect(database_url)
        # The shared backend keeps heavy screens warm so nobody waits on a cold heatmap.
        # (Not the Mac's local fallback: same home IP, it would double the Yahoo traffic.)
        warm = asyncio.create_task(_keep_warm()) if database_url else None
        yield
        if warm:
            warm.cancel()

    app = FastAPI(title="finops-gateway", lifespan=lifespan)
    app.state.devices = devices
    hub = hub or Hub()

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.websocket("/ws")
    async def ws(socket: WebSocket) -> None:
        store: DeviceStore | None = app.state.devices
        if store is None:
            if token is None or not secrets.compare_digest(socket.query_params.get("token", ""), token):
                await socket.close(code=4401)
                return
            await socket.accept()
        else:
            await socket.accept()
            if not await authenticate(socket, store):
                await socket.close(code=4401)
                return
        await Connection(socket, hub).run()

    return app


async def authenticate(socket: WebSocket, store: DeviceStore) -> bool:
    """First message must be remote.pair or remote.auth (same wire format as the Mac's LAN pairing)."""
    try:
        hello = await asyncio.wait_for(socket.receive_json(), AUTH_TIMEOUT)
    except (TimeoutError, WebSocketDisconnect, ValueError):
        return False
    kind = hello.get("t")
    device_id = str(hello.get("deviceID", ""))[:128]
    if kind == "remote.pair" and device_id:
        token = await store.pair(str(hello.get("code", "")), device_id, str(hello.get("deviceName", "device"))[:64])
        if token:
            log.info("paired device %s (%s)", device_id, hello.get("deviceName"))
            await socket.send_json({"t": "remote.paired", "token": token, "macName": BACKEND_NAME})
            return True
        await socket.send_json({"t": "remote.authFailed",
                                "reason": "Wrong or expired code. Create one with: finops-admin pair"})
        return False
    if kind == "remote.auth" and device_id:
        if await store.verify(device_id, str(hello.get("token", ""))):
            await socket.send_json({"t": "remote.authOK", "macName": BACKEND_NAME})
            return True
        await socket.send_json({"t": "remote.authFailed", "reason": "This device is not paired with the backend. Pair it again."})
        return False
    await socket.send_json({"t": "remote.authFailed", "reason": "Authentication required"})
    return False


class Connection:
    def __init__(self, socket: WebSocket, hub: Hub) -> None:
        self.socket = socket
        self.hub = hub
        self.send_lock = asyncio.Lock()
        self.subs: dict[str, tuple[str, Any]] = {}  # cid -> (symbol, sink)
        self.tasks: set[asyncio.Task[None]] = set()

    async def send(self, message: dict[str, Any]) -> None:
        async with self.send_lock:
            await self.socket.send_json(message)

    async def run(self) -> None:
        try:
            while True:
                msg = await self.socket.receive_json()
                task = asyncio.create_task(self.handle(msg))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
        except WebSocketDisconnect:
            pass
        finally:
            for task in self.tasks:
                task.cancel()
            for symbol, sink in self.subs.values():
                self.hub.unsubscribe(symbol, sink)

    async def handle(self, msg: dict[str, Any]) -> None:
        cid = str(msg.get("cid", ""))
        try:
            match msg.get("t"):
                case str(t) if t.startswith("remote."):
                    return  # keypad relay is phase 5; ignore for now
                case "request":
                    data = await self.request(msg.get("service"), msg.get("params") or {})
                    await self.send({"t": "response", "cid": cid, "data": data})
                case "subscribe":
                    await self.subscribe(cid, str(msg.get("security", "")))
                case "unsubscribe":
                    if cid in self.subs:
                        symbol, sink = self.subs.pop(cid)
                        self.hub.unsubscribe(symbol, sink)
                        await self.send({"t": "subStatus", "cid": cid, "status": "terminated"})
                case other:
                    raise ValueError(f"unknown message type {other!r}")
        except YFRateLimitError:
            await self.send({"t": "error", "cid": cid, "code": "rate_limited", "message": yahoo_guard.message()})
        except (ValueError, LookupError, HTTPError) as exc:
            await self.send({"t": "error", "cid": cid, "code": "bad_request", "message": str(exc)})
        except Exception as exc:
            log.exception("request failed")
            await self.send({"t": "error", "cid": cid, "code": "provider_error", "message": str(exc)})

    async def request(self, service: str | None, params: dict[str, Any]) -> dict[str, Any]:
        p = {k: str(v) for k, v in params.items()}

        def symbol() -> str:
            """Yahoo symbol for Yahoo-backed screens (a crypto pair maps to e.g. BTC-USD)."""
            return securities.resolve(p.get("security", "")).yahoo_symbol

        match service:
            case "refdata":
                sec = securities.resolve(p.get("security", ""))
                if sec.provider == "binance":
                    quote = await asyncio.to_thread(binance.quote, sec.symbol)
                    return {"security": _sec(sec, binance.name(sec.symbol)), "quote": quote}
                quote, name = await asyncio.gather(
                    asyncio.to_thread(yahoo.quote, sec.symbol),
                    asyncio.to_thread(yahoo.name, sec.symbol),
                )
                return {"security": _sec(sec, name), "quote": quote}
            case "history":
                sec = securities.resolve(p.get("security", ""))
                source = binance if sec.provider == "binance" else yahoo
                series = await asyncio.to_thread(source.history, sec.symbol, p.get("range", "1Y").upper(),
                                                 (p.get("interval") or "").upper() or None)
                return {"security": _sec(sec, None), **series}
            case "lookup":
                found, coins = await asyncio.gather(asyncio.to_thread(yahoo.lookup, p.get("query", "")),
                                                    asyncio.to_thread(binance.lookup, p.get("query", ""), 3))
                # Binance pairs first: Yahoo's crypto quotes are delayed snapshots.
                return {**found, "results": coins + found["results"]}
            case "config":
                # Empty values never erase a key configured on the server (.env).
                if p.get("edgarContact", "").strip():
                    settings.edgar_contact = p["edgarContact"].strip()
                if p.get("fredApiKey", "").strip():
                    settings.fred_api_key = p["fredApiKey"].strip()
                    fred.dashboard.cache_clear()
                if p.get("anthropicApiKey", "").strip():
                    settings.anthropic_api_key = p["anthropicApiKey"].strip()
                return {"ok": True, "fred": bool(settings.fred_api_key), "anthropic": bool(settings.anthropic_api_key)}
            # Lot 1 — company
            case "profile":
                return await asyncio.to_thread(research.profile, symbol())
            case "news":
                if p.get("security") and (sec := securities.resolve(p["security"])).provider == "binance":
                    return await asyncio.to_thread(crypto_news.news, split_pair(sec.symbol)[0])
                if p.get("query", "").strip().upper() in ("CRYPTO", "CRYPTOS"):
                    return await asyncio.to_thread(crypto_news.news)
                query = symbol() if p.get("security") else (p.get("query") or "stock market")
                return await asyncio.to_thread(research.news, query)
            case "estimates":
                return await asyncio.to_thread(research.estimates, symbol())
            case "events":
                return await asyncio.to_thread(research.events, symbol())
            case "holders":
                return await asyncio.to_thread(research.holders, symbol())
            case "financials":
                return await asyncio.to_thread(edgar.financials, symbol(), p.get("period", "A").upper(),
                                               p.get("statement", "IS").upper())
            case "filings":
                return await asyncio.to_thread(edgar.filings, symbol(), p.get("group", "ALL").upper())
            # Lot 2 — markets
            case "options":
                return await asyncio.to_thread(research.options, symbol(), p.get("expiry") or None)
            case "market":
                return await asyncio.to_thread(research.market)
            case "movers":
                return await asyncio.to_thread(research.movers, p.get("kind", "GAINERS"))
            case "screen":
                return await asyncio.to_thread(research.screen, tuple(p.get("filters", "").split()))
            # Lot 3 — macro
            case "econ":
                return await asyncio.to_thread(fred.dashboard)
            case "econ_series":
                return await asyncio.to_thread(fred.series, p.get("id", "").upper(), p.get("range", "10Y").upper(),
                                               p.get("units", "lin"))
            case "econ_search":
                return await asyncio.to_thread(fred.search, p.get("query", ""))
            case "curve":
                return await asyncio.to_thread(fred.curve)
            # Visual & analytics screens
            case "heatmap":
                return await asyncio.to_thread(views.heatmap, p.get("sector") or None, p.get("period", "1D").upper())
            case "fxmatrix":
                return await asyncio.to_thread(views.fx_matrix)
            case "perf":
                return await asyncio.to_thread(views.perf, p.get("securities", ""))
            case "grid":
                return await asyncio.to_thread(views.grid, p.get("securities", ""), p.get("range", "3M").upper())
            case "corr":
                return await asyncio.to_thread(views.correlation, p.get("securities", ""), p.get("range", "1Y").upper())
            case "rv":
                return await asyncio.to_thread(views.relative_value, symbol(), p.get("x", "FPE").upper(), p.get("y", "GROWTH").upper())
            case "rels":
                return await asyncio.to_thread(views.relationships, symbol())
            case "dcf":
                def pct(key: str) -> float | None:
                    return float(p[key]) / 100 if p.get(key) else None
                return await asyncio.to_thread(views.dcf, symbol(), pct("wacc"), pct("growth"), pct("terminal"))
            case "portfolio":
                return await asyncio.to_thread(views.portfolio, p.get("positions", ""))
            case "worldbank":
                return await asyncio.to_thread(views.world_bank, p.get("indicator", "GDP").upper())
            case "centralbanks":
                return await asyncio.to_thread(views.central_banks)
            case "etf":
                if p.get("security"):
                    return await asyncio.to_thread(views.etf, symbol())
                return await asyncio.to_thread(views.etf_market, p.get("list", "TOP").upper())
            case "calendar":
                return await asyncio.to_thread(views.calendar, p.get("kind", "ECO").upper(), p.get("span", "WEEK").upper(),
                                               p.get("region", "MAJOR").upper())
            case "article":
                # Not p[...]: URLs are case-sensitive and must reach the provider untouched.
                return await asyncio.to_thread(article.read, str(params.get("url", "")).strip())
            case "markers":
                return await asyncio.to_thread(intel_markers.markers, p.get("security", ""), p.get("range", "1Y").upper())
            case "why":
                return await asyncio.to_thread(intel_why.why, p.get("security", ""))
            case "study":
                return await asyncio.to_thread(intel_study.study, p.get("security") or "SPX IDX",
                                               [a for a in p.get("args", "").upper().split() if a])
            case "rules":
                # The rules JSON is case-sensitive (ids, keywords): read it from the raw params.
                return await asyncio.to_thread(intel_rules.evaluate, str(params.get("rules", "[]")))
            case "rule_presets":
                return intel_rules.presets()
            case "case_feed":
                return await asyncio.to_thread(intel_exposure.case_feed, str(params.get("terms", "")))
            case "exposure":
                return await asyncio.to_thread(intel_exposure.exposure, p.get("positions", ""))
            case "world":
                return await asyncio.to_thread(intel.world_screen, p.get("kind", "ALL").upper(), int(p.get("severity") or 1))
            case "link":
                return await asyncio.to_thread(intel.link_screen, p.get("query") or p.get("security", ""))
            case "rwa":
                return await asyncio.to_thread(rwa.rwa, p.get("kind", "OVERVIEW"))
            case "crypto":
                if p.get("security"):
                    sec = securities.resolve(p["security"])
                    if sec.provider != "binance":
                        raise ValueError(f"{sec.typed} is not a crypto pair; try BTC CRYPTO")
                    return await asyncio.to_thread(binance.detail, sec.symbol)
                return await asyncio.to_thread(binance.market, p.get("quote", "USDT").upper())
            case "sentiment":
                return await asyncio.to_thread(views.sentiment, symbol())
            case _:
                raise ValueError(f"unknown service {service!r}")

    async def subscribe(self, cid: str, typed: str) -> None:
        sec = securities.resolve(typed)

        async def sink(kind: str, payload: dict[str, Any]) -> None:
            if kind == "tick":
                await self.send({"t": "tick", "cid": cid, "data": payload})
            else:
                await self.send({"t": kind, "cid": cid, **payload})

        await self.send({"t": "subStatus", "cid": cid, "status": "started"})
        self.subs[cid] = (self.hub.subscribe(sec.symbol, sink, sec.provider), sink)


WARM = [
    ("heatmap", lambda: views.heatmap(None, "1D")),
    ("market", lambda: research.market()),
    ("fxmatrix", lambda: views.fx_matrix()),
    ("world", lambda: intel.world_screen("ALL")),
    ("crypto", lambda: binance.market("USDT")),
]


async def _keep_warm(every: float = 240) -> None:
    await asyncio.sleep(5)
    while True:
        for name, build in WARM:
            try:
                await asyncio.to_thread(build)
            except Exception as exc:
                log.info("warm-up of %s failed: %s", name, exc)
        await asyncio.sleep(every)


def _sec(sec: securities.Security, name: str | None) -> dict[str, Any]:
    return {"typed": sec.typed, "symbol": sec.symbol, "assetClass": sec.asset_class, "name": name}
