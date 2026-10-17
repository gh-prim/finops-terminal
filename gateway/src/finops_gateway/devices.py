"""Paired devices and one-time pairing codes.

Same model as the Mac's LAN pairing: a short-lived 6-digit code (created with
`finops-admin pair`) is exchanged for a random bearer token. Only SHA-256 hashes
of codes and tokens are stored.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from typing import Protocol

CODE_LIFETIME = dt.timedelta(minutes=5)
MAX_ATTEMPTS = 5


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def new_token() -> str:
    return secrets.token_urlsafe(32)


def new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


@dataclass
class Device:
    id: str
    name: str
    created_at: dt.datetime
    last_seen: dt.datetime | None


class DeviceStore(Protocol):
    async def create_code(self) -> str: ...
    async def pair(self, code: str, device_id: str, name: str) -> str | None: ...
    async def verify(self, device_id: str, token: str) -> Device | None: ...
    async def list(self) -> list[Device]: ...
    async def revoke(self, device_id: str) -> bool: ...


class MemoryDeviceStore:
    """In-process store (tests, local development)."""

    def __init__(self) -> None:
        self.codes: dict[str, tuple[dt.datetime, int]] = {}  # code hash -> (expires, attempts)
        self.devices: dict[str, tuple[Device, str]] = {}      # id -> (device, token hash)

    async def create_code(self) -> str:
        code = new_code()
        self.codes[sha256(code)] = (dt.datetime.now(dt.UTC) + CODE_LIFETIME, 0)
        return code

    async def pair(self, code: str, device_id: str, name: str) -> str | None:
        now = dt.datetime.now(dt.UTC)
        self.codes = {h: v for h, v in self.codes.items() if v[0] > now and v[1] < MAX_ATTEMPTS}
        if sha256(code) not in self.codes:
            # Count a failed attempt against every live code (we can't know which one was meant).
            self.codes = {h: (e, a + 1) for h, (e, a) in self.codes.items()}
            return None
        del self.codes[sha256(code)]
        token = new_token()
        self.devices[device_id] = (Device(device_id, name, now, now), sha256(token))
        return token

    async def verify(self, device_id: str, token: str) -> Device | None:
        entry = self.devices.get(device_id)
        if not entry or not hmac.compare_digest(entry[1], sha256(token)):
            return None
        entry[0].last_seen = dt.datetime.now(dt.UTC)
        return entry[0]

    async def list(self) -> list[Device]:
        return [d for d, _ in self.devices.values()]

    async def revoke(self, device_id: str) -> bool:
        return self.devices.pop(device_id, None) is not None


SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id          text PRIMARY KEY,
    name        text NOT NULL,
    token_hash  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz
);
CREATE TABLE IF NOT EXISTS pairing_codes (
    code_hash   text PRIMARY KEY,
    expires_at  timestamptz NOT NULL,
    attempts    int NOT NULL DEFAULT 0
);
"""


class PostgresDeviceStore:
    def __init__(self, pool) -> None:  # asyncpg.Pool
        self.pool = pool

    @classmethod
    async def connect(cls, dsn: str) -> PostgresDeviceStore:
        import asyncpg

        pool = await asyncpg.create_pool(dsn, min_size=1, max_size=4)
        async with pool.acquire() as conn:
            await conn.execute(SCHEMA)
        return cls(pool)

    async def create_code(self) -> str:
        code = new_code()
        async with self.pool.acquire() as conn:
            await conn.execute("DELETE FROM pairing_codes WHERE expires_at < now()")
            await conn.execute("INSERT INTO pairing_codes (code_hash, expires_at) VALUES ($1, $2)",
                               sha256(code), dt.datetime.now(dt.UTC) + CODE_LIFETIME)
        return code

    async def pair(self, code: str, device_id: str, name: str) -> str | None:
        async with self.pool.acquire() as conn, conn.transaction():
            await conn.execute("DELETE FROM pairing_codes WHERE expires_at < now() OR attempts >= $1", MAX_ATTEMPTS)
            row = await conn.fetchrow("DELETE FROM pairing_codes WHERE code_hash = $1 RETURNING code_hash", sha256(code))
            if row is None:
                await conn.execute("UPDATE pairing_codes SET attempts = attempts + 1")
                return None
            token = new_token()
            await conn.execute(
                """INSERT INTO devices (id, name, token_hash, last_seen) VALUES ($1, $2, $3, now())
                   ON CONFLICT (id) DO UPDATE SET name = $2, token_hash = $3, last_seen = now()""",
                device_id, name, sha256(token))
            return token

    async def verify(self, device_id: str, token: str) -> Device | None:
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow("SELECT * FROM devices WHERE id = $1", device_id)
            if row is None or not hmac.compare_digest(row["token_hash"], sha256(token)):
                return None
            await conn.execute("UPDATE devices SET last_seen = now() WHERE id = $1", device_id)
            return Device(row["id"], row["name"], row["created_at"], row["last_seen"])

    async def list(self) -> list[Device]:
        async with self.pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM devices ORDER BY created_at")
        return [Device(r["id"], r["name"], r["created_at"], r["last_seen"]) for r in rows]

    async def revoke(self, device_id: str) -> bool:
        async with self.pool.acquire() as conn:
            return (await conn.execute("DELETE FROM devices WHERE id = $1", device_id)).endswith(" 1")
