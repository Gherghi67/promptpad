"""Production server/dispatcher over an inherited AF_UNIX socket; never imports iTerm2.

Invoked only by PythonInteropTests. Standard input is a socketpair endpoint,
which works even in sandboxes that prohibit binding filesystem sockets.
"""

import asyncio
import json
import os
import socket
import sys

from bridge.server import BridgeServer
from bridge.tests.test_bridge import backend


class FragmentedWriter:
    def __init__(self, writer):
        self.writer = writer
        self.pending = b""

    def __getattr__(self, name):
        return getattr(self.writer, name)

    def write(self, data):
        self.pending += data

    async def drain(self):
        # Split both the length prefix and multibyte JSON across writes.
        for byte in self.pending:
            self.writer.write(bytes([byte]))
            await self.writer.drain()
            await asyncio.sleep(0)
        self.pending = b""


async def main():
    terminal = backend()
    app = terminal.app
    mode = sys.argv[1]
    if mode == "changed":
        app.tab.current_session = app.other
        app.raw_session = "s2"
    elif mode == "gone":
        del app.sessions["s1"]
    server = BridgeServer(terminal)
    peer = socket.socket(fileno=os.dup(0))
    peer.setblocking(False)
    reader, writer = await asyncio.open_connection(sock=peer)
    try:
        await asyncio.wait_for(server.serve(reader, FragmentedWriter(writer)), 10)
    finally:
        # Only test data is emitted, never live terminal content.
        print(json.dumps({"sent": app.session.sent, "other_sent": app.other.sent,
                          "lookups": app.lookups}), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
