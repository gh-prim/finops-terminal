"""`finops-admin`: manage paired devices on the backend.

    docker exec -it finops-api-1 finops-admin pair      # one-time 6-digit code (5 min)
    docker exec -it finops-api-1 finops-admin devices
    docker exec -it finops-api-1 finops-admin revoke <device-id>
"""

from __future__ import annotations

import argparse
import asyncio
import os

from .devices import CODE_LIFETIME, PostgresDeviceStore


async def run(args: argparse.Namespace) -> None:
    store = await PostgresDeviceStore.connect(os.environ["DATABASE_URL"])
    match args.command:
        case "pair":
            code = await store.create_code()
            print(f"Pairing code: {code[:3]} {code[3:]}  (valid {int(CODE_LIFETIME.total_seconds() // 60)} min)")
        case "devices":
            devices = await store.list()
            if not devices:
                print("No paired devices.")
            for d in devices:
                seen = d.last_seen.strftime("%Y-%m-%d %H:%M") if d.last_seen else "never"
                print(f"{d.id}  {d.name:<24} paired {d.created_at:%Y-%m-%d}  last seen {seen}")
        case "revoke":
            print("Revoked." if await store.revoke(args.device_id) else "No such device.")


def main() -> None:
    parser = argparse.ArgumentParser(prog="finops-admin")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("pair", help="create a one-time pairing code")
    sub.add_parser("devices", help="list paired devices")
    revoke = sub.add_parser("revoke", help="revoke a device")
    revoke.add_argument("device_id")
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
