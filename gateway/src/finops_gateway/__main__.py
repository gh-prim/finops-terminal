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
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default=os.environ.get("FINOPS_GATEWAY_TOKEN", "dev"))
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.parent_pid:
        threading.Thread(target=_exit_with_parent, args=(args.parent_pid,), daemon=True).start()

    uvicorn.run(create_app(args.token), host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
