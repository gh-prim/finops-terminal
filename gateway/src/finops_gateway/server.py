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
import logging
import secrets
from typing import Any

from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from . import securities
from .config import settings
from .devices import DeviceStore, PostgresDeviceStore
from .hub import Hub
from .providers import edgar, fred, yahoo
from .providers import yahoo_research as research
from .providers.http import HTTPError

log = logging.getLogger(__name__)


BACKEND_NAME = "finops-backend"
AUTH_TIMEOUT = 10


def create_app(token: str | None = None, hub: Hub | None = None, devices: DeviceStore | None = None,
               database_url: str | None = None) -> FastAPI:
    """`token`: single shared secret (the Mac's local sidecar).
    `devices` / `database_url`: per-device pairing (the shared backend)."""

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if database_url and app.state.devices is None:
            app.state.devices = await PostgresDeviceStore.connect(database_url)
        yield

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
        except (ValueError, LookupError, HTTPError) as exc:
            await self.send({"t": "error", "cid": cid, "code": "bad_request", "message": str(exc)})
        except Exception as exc:
            log.exception("request failed")
            await self.send({"t": "error", "cid": cid, "code": "provider_error", "message": str(exc)})

    async def request(self, service: str | None, params: dict[str, Any]) -> dict[str, Any]:
        p = {k: str(v) for k, v in params.items()}

        def symbol() -> str:
            return securities.resolve(p.get("security", "")).symbol

        match service:
            case "refdata":
                sec = securities.resolve(p.get("security", ""))
                quote, name = await asyncio.gather(
                    asyncio.to_thread(yahoo.quote, sec.symbol),
                    asyncio.to_thread(yahoo.name, sec.symbol),
                )
                return {"security": _sec(sec, name), "quote": quote}
            case "history":
                sec = securities.resolve(p.get("security", ""))
                series = await asyncio.to_thread(yahoo.history, sec.symbol, p.get("range", "1Y").upper())
                return {"security": _sec(sec, None), **series}
            case "lookup":
                return await asyncio.to_thread(yahoo.lookup, p.get("query", ""))
            case "config":
                if "edgarContact" in p:
                    settings.edgar_contact = p["edgarContact"].strip()
                if "fredApiKey" in p:
                    settings.fred_api_key = p["fredApiKey"].strip()
                    fred.dashboard.cache_clear()
                return {"ok": True, "fred": bool(settings.fred_api_key)}
            # Lot 1 — company
            case "profile":
                return await asyncio.to_thread(research.profile, symbol())
            case "news":
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
            case _:
                raise ValueError(f"unknown service {service!r}")

    async def subscribe(self, cid: str, typed: str) -> None:
        sec = securities.resolve(typed)

        async def sink(kind: str, payload: dict[str, Any]) -> None:
            if kind == "tick":
                await self.send({"t": "tick", "cid": cid, "data": payload})
            else:
                await self.send({"t": kind, "cid": cid, **payload})

        self.subs[cid] = (sec.symbol, sink)
        await self.send({"t": "subStatus", "cid": cid, "status": "started"})
        self.hub.subscribe(sec.symbol, sink)


def _sec(sec: securities.Security, name: str | None) -> dict[str, Any]:
    return {"typed": sec.typed, "symbol": sec.symbol, "assetClass": sec.asset_class, "name": name}
