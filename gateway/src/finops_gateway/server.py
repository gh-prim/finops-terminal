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

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from . import securities
from .hub import Hub
from .providers import yahoo

log = logging.getLogger(__name__)


def create_app(token: str, hub: Hub | None = None) -> FastAPI:
    app = FastAPI(title="finops-gateway")
    hub = hub or Hub()

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.websocket("/ws")
    async def ws(socket: WebSocket) -> None:
        if not secrets.compare_digest(socket.query_params.get("token", ""), token):
            await socket.close(code=4401)
            return
        await socket.accept()
        await Connection(socket, hub).run()

    return app


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
        except (ValueError, LookupError) as exc:
            await self.send({"t": "error", "cid": cid, "code": "bad_request", "message": str(exc)})
        except Exception as exc:
            log.exception("request failed")
            await self.send({"t": "error", "cid": cid, "code": "provider_error", "message": str(exc)})

    async def request(self, service: str | None, params: dict[str, Any]) -> dict[str, Any]:
        match service:
            case "refdata":
                sec = securities.resolve(str(params.get("security", "")))
                quote, name = await asyncio.gather(
                    asyncio.to_thread(yahoo.quote, sec.symbol),
                    asyncio.to_thread(yahoo.name, sec.symbol),
                )
                return {"security": _sec(sec, name), "quote": quote}
            case "history":
                sec = securities.resolve(str(params.get("security", "")))
                range_code = str(params.get("range", "1Y")).upper()
                series = await asyncio.to_thread(yahoo.history, sec.symbol, range_code)
                return {"security": _sec(sec, None), **series}
            case "lookup":
                return await asyncio.to_thread(yahoo.lookup, str(params.get("query", "")))
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
