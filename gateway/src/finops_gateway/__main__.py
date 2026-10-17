"""Entry point: `finops-gateway --port N --token T [--parent-pid P]`."""

from __future__ import annotations

import argparse
import logging
import os
import signal
import threading
import time

import uvicorn

from .server import create_app


def _exit_with_parent(parent_pid: int) -> None:
    # If the app dies without stopping us, don't linger as an orphan. The app is
    # not necessarily our direct parent (`uv run` sits in between), so check the
    # pid itself rather than getppid().
    while True:
        time.sleep(2)
        try:
            os.kill(parent_pid, 0)
        except ProcessLookupError:
            os.kill(os.getpid(), signal.SIGTERM)
            return
        except PermissionError:
            pass  # exists but owned by someone else; keep running


def main() -> None:
    parser = argparse.ArgumentParser(prog="finops-gateway")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (0.0.0.0 inside a container)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default=os.environ.get("FINOPS_GATEWAY_TOKEN", "dev"))
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--auth", choices=["token", "devices"], default="token",
                        help="token: shared secret (local sidecar); devices: per-device pairing in Postgres")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.parent_pid:
        threading.Thread(target=_exit_with_parent, args=(args.parent_pid,), daemon=True).start()

    if args.auth == "devices":
        app = create_app(database_url=os.environ["DATABASE_URL"])
    else:
        app = create_app(args.token)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
