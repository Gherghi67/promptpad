"""One-client, one-action Unix socket server with private filesystem ownership."""

import asyncio
import contextlib
import errno
import fcntl
import os
from pathlib import Path
import socket
import stat
import struct

from .protocol import MAX_FRAME, Failure, decode, encode, error, valid_id, validate


class PrivateSocket:
    def __init__(self, directory=None):
        self.uid = os.getuid()
        self.directory = Path(directory or f"/tmp/gamepad-terminal-{self.uid}")
        self.path = self.directory / "bridge.sock"
        self.lock_fd = None
        self.socket_identity = None

    def checked(self, path, kind, mode):
        info = path.lstat()
        if not kind(info.st_mode) or info.st_uid != self.uid or stat.S_IMODE(info.st_mode) != mode:
            raise PermissionError(f"Unsafe bridge filesystem entry: {path}")
        return info

    @staticmethod
    def identity(info):
        return info.st_dev, info.st_ino

    def acquire(self):
        os.umask(0o077)
        try:
            self.directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        self.checked(self.directory, stat.S_ISDIR, 0o700)
        lock = self.directory / "bridge.lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            named = self.checked(lock, stat.S_ISREG, 0o600)
            if info.st_nlink != 1 or self.identity(info) != self.identity(named):
                raise PermissionError("Unsafe bridge lock file.")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.lock_fd = fd
        except BaseException:
            os.close(fd)
            raise
        try:
            try:
                info = self.checked(self.path, stat.S_ISSOCK, 0o600)
            except FileNotFoundError:
                return
            # Even with our lock, never remove a listening endpoint left by an
            # independently running process. Only ECONNREFUSED proves staleness.
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.2)
                try:
                    probe.connect(str(self.path))
                except OSError as exc:
                    if exc.errno != errno.ECONNREFUSED:
                        raise
                else:
                    raise BlockingIOError("A live bridge socket already exists.")
            if self.identity(self.path.lstat()) != self.identity(info):
                raise PermissionError("Bridge socket changed during startup.")
            self.path.unlink()
        except BaseException:
            self.release()
            raise

    def bind(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self.socket_identity = self.identity(self.checked(self.path, stat.S_ISSOCK, 0o600))
            listener.setblocking(False)
            return listener
        except BaseException:
            listener.close()
            raise

    def release(self):
        if self.socket_identity is not None:
            try:
                info = self.checked(self.path, stat.S_ISSOCK, 0o600)
                if self.identity(info) == self.socket_identity:
                    self.path.unlink()
            except (FileNotFoundError, PermissionError):
                pass
            self.socket_identity = None
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None


def same_user(peer):
    if hasattr(peer, "getpeereid"):
        return peer.getpeereid()[0] == os.getuid()
    if hasattr(socket, "SO_PEERCRED"):
        _, uid, _ = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        return uid == os.getuid()
    if hasattr(socket, "LOCAL_PEERCRED"):
        # Darwin struct xucred: uint32 version, uid_t uid, short ngroups, ...
        credential = peer.getsockopt(0, socket.LOCAL_PEERCRED, 128)
        version, uid = struct.unpack_from("=II", credential)
        return version == 0 and uid == os.getuid()
    # No supported peer-credential facility on this platform. Filesystem
    # permissions still restrict access; macOS and Linux take branches above.
    return True


class BridgeServer:
    def __init__(self, backend, directory=None, frame_timeout=2, operation_timeout=2,
                 request_timeout=3):
        self.backend = backend
        self.private = PrivateSocket(directory)
        self.frame_timeout = frame_timeout
        self.operation_timeout = operation_timeout
        self.request_timeout = request_timeout
        self.server = None
        self.client = None
        self.clients = set()
        self.in_flight = False
        self.unhealthy = False
        self.failed = asyncio.Event()

    async def start(self):
        self.private.acquire()
        try:
            listener = self.private.bind()
            try:
                self.server = await asyncio.start_unix_server(self.accept, sock=listener, limit=MAX_FRAME + 4)
            except BaseException:
                listener.close()
                raise
        except BaseException:
            self.private.release()
            raise

    def accept(self, reader, writer):
        # This callback contains no await: claim the single client synchronously.
        try:
            peer_ok = same_user(writer.get_extra_info("socket"))
        except OSError:
            peer_ok = False
        if self.client is not None or self.unhealthy or not peer_ok:
            writer.close()
            return
        task = asyncio.create_task(self.serve(reader, writer))
        self.client = task
        self.clients.add(task)
        task.add_done_callback(self.clients.discard)

    async def frame(self, reader):
        # Idle streams are allowed; the absolute deadline starts on the first
        # byte and covers both the remaining header and complete payload.
        first = await reader.readexactly(1)
        started = asyncio.get_running_loop().time()

        async def remainder():
            header = first + await reader.readexactly(3)
            length = struct.unpack("!I", header)[0]
            if not 1 <= length <= MAX_FRAME:
                raise Failure("too_large", "Invalid frame size.")
            return await reader.readexactly(length)

        payload = await asyncio.wait_for(remainder(), self.frame_timeout)
        return payload, started

    async def act(self, request, reader, remaining):
        if self.in_flight:
            raise Failure("busy", "An iTerm2 operation is already running.")
        self.in_flight = True
        self.backend.mutation_started = False
        operation = asyncio.create_task(self.backend.dispatch(request))
        extra = asyncio.create_task(reader.read(1))
        try:
            done, _ = await asyncio.wait({operation, extra}, timeout=min(self.operation_timeout, remaining),
                                         return_when=asyncio.FIRST_COMPLETED)
            if extra in done:
                # A disconnect or any pipelined byte invalidates this stream.
                raise ConnectionError("Client disconnected or pipelined a request.")
            if operation not in done:
                self.unhealthy = True
                code = "outcome_unknown" if self.backend.mutation_started else "timeout"
                raise Failure(code, "iTerm2 operation expired. Inspect the target before continuing.")
            return operation.result()
        except Failure:
            raise
        except BaseException:
            # Cancellation or an RPC failure after dispatch may have delivered
            # a mutation. Do not reuse that backend for a subsequent client.
            self.unhealthy = True
            raise
        finally:
            for task in (operation, extra):
                if not task.done():
                    task.cancel()
            # Transaction.__aexit__ itself makes an RPC. A wedged backend must
            # not hold this stream open indefinitely while cancellation unwinds.
            _, pending = await asyncio.wait({operation, extra}, timeout=0.1)
            if pending:
                self.unhealthy = True
                for task in pending:
                    task.cancel()
                    task.add_done_callback(self.consume_result)
            for task in (operation, extra):
                if task.done():
                    self.consume_result(task)
            self.in_flight = False

    @staticmethod
    def consume_result(task):
        if not task.cancelled():
            task.exception()

    async def serve(self, reader, writer):
        try:
            while not self.unhealthy:
                payload, started = await self.frame(reader)
                request = decode(payload)
                if type(request) is not dict or not valid_id(request.get("id")):
                    return
                close_after = False
                try:
                    validate(request)
                    remaining = self.request_timeout - (asyncio.get_running_loop().time() - started)
                    if remaining <= 0:
                        return
                    response = await self.act(request, reader, remaining)
                except Failure as exc:
                    response = error(request["id"], exc)
                    close_after = self.unhealthy
                except (ConnectionError, asyncio.CancelledError):
                    raise
                except Exception:
                    # Never expose RPC exception text: it can contain terminal
                    # content, credentials or user-supplied dictated text.
                    code = "outcome_unknown" if self.backend.mutation_started else "disconnected"
                    response = error(request["id"], Failure(code, "iTerm2 connection failed. Inspect the target and restart the bridge."))
                    close_after = True
                    self.unhealthy = True
                remaining = self.request_timeout - (asyncio.get_running_loop().time() - started)
                if remaining <= 0:
                    return
                writer.write(encode(response))
                await asyncio.wait_for(writer.drain(), min(self.frame_timeout, remaining))
                if close_after:
                    return
        except (Failure, OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            pass  # No trustworthy request ID for malformed/truncated frames.
        finally:
            writer.close()
            with contextlib.suppress(OSError, asyncio.TimeoutError):
                await asyncio.wait_for(writer.wait_closed(), self.frame_timeout)
            if self.client is asyncio.current_task():
                self.client = None
            if self.unhealthy:
                self.failed.set()

    async def close(self):
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()
            self.server = None
        tasks = list(self.clients)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.private.release()
