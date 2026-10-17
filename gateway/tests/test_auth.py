import asyncio

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from finops_gateway.devices import MAX_ATTEMPTS, MemoryDeviceStore
from finops_gateway.server import create_app


@pytest.fixture
def store() -> MemoryDeviceStore:
    return MemoryDeviceStore()


@pytest.fixture
def client(store: MemoryDeviceStore) -> TestClient:
    return TestClient(create_app(devices=store))


def pair(client: TestClient, code: str, device: str = "ipad-1") -> dict:
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "remote.pair", "code": code, "deviceID": device, "deviceName": "iPad"})
        return ws.receive_json()


def test_pair_then_auth_then_data(client: TestClient, store: MemoryDeviceStore) -> None:
    code = asyncio.run(store.create_code())
    reply = pair(client, code)
    assert reply["t"] == "remote.paired" and reply["macName"] == "finops-backend"
    token = reply["token"]

    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "remote.auth", "token": token, "deviceID": "ipad-1"})
        assert ws.receive_json()["t"] == "remote.authOK"
        ws.send_json({"t": "request", "cid": "1", "service": "nope", "params": {}})
        assert ws.receive_json() == {"t": "error", "cid": "1", "code": "bad_request", "message": "unknown service 'nope'"}


def test_code_is_single_use(client: TestClient, store: MemoryDeviceStore) -> None:
    code = asyncio.run(store.create_code())
    assert pair(client, code)["t"] == "remote.paired"
    assert pair(client, code, device="other")["t"] == "remote.authFailed"


def test_wrong_codes_burn_the_live_code(client: TestClient, store: MemoryDeviceStore) -> None:
    code = asyncio.run(store.create_code())
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(MAX_ATTEMPTS):
        assert pair(client, wrong)["t"] == "remote.authFailed"
    assert pair(client, code)["t"] == "remote.authFailed"


def test_bad_token_and_missing_hello_are_rejected(client: TestClient) -> None:
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "remote.auth", "token": "nope", "deviceID": "x"})
        assert ws.receive_json()["t"] == "remote.authFailed"
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "request", "cid": "1", "service": "refdata", "params": {}})
        assert ws.receive_json()["t"] == "remote.authFailed"
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


def test_revoked_device_cannot_auth(client: TestClient, store: MemoryDeviceStore) -> None:
    token = pair(client, asyncio.run(store.create_code()))["token"]
    assert asyncio.run(store.revoke("ipad-1"))
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"t": "remote.auth", "token": token, "deviceID": "ipad-1"})
        assert ws.receive_json()["t"] == "remote.authFailed"


def test_token_mode_unchanged() -> None:
    client = TestClient(create_app("secret"))
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws?token=wrong") as ws:
            ws.receive_json()
    with client.websocket_connect("/ws?token=secret") as ws:
        ws.send_json({"t": "request", "cid": "1", "service": "nope", "params": {}})
        assert ws.receive_json()["t"] == "error"
