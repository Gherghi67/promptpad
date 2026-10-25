"""Run with iTerm2's bundled Python, from the repository root: -m bridge."""

import asyncio
import contextlib
import signal
import sys

from .backend import ITermBackend
from .server import BridgeServer


async def run(connection, api):
    app = await asyncio.wait_for(api.async_get_app(connection), 2)
    server = BridgeServer(ITermBackend(connection, app, api))
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stopped.set)
    waiting = []
    try:
        await server.start()
        print(f"Gamepad Terminal bridge ready: {server.private.path}", flush=True)
        waiting = [asyncio.create_task(stopped.wait()), asyncio.create_task(server.failed.wait())]
        await asyncio.wait(waiting, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in waiting:
            task.cancel()
        await asyncio.gather(*waiting, return_exceptions=True)
        await server.close()
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(signum)
    if server.unhealthy:
        print("iTerm2 connection lost or operation uncertain; bridge stopped. Inspect the target, then restart.", file=sys.stderr)


def main():
    try:
        import iterm2
    except ImportError:
        print("Use iTerm2's Python runtime; see bridge/README.md.", file=sys.stderr)
        return 1
    try:
        iterm2.run_until_complete(lambda connection: run(connection, iterm2), retry=False)
    except (OSError, asyncio.TimeoutError):
        print("Bridge startup failed. Check iTerm2 API access and whether another bridge is running.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        sys.exit(main())
