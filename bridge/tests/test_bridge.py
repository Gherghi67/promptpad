import asyncio
import errno
import os
from pathlib import Path
import socket
import stat
import struct
import tempfile
from types import SimpleNamespace as NS
import unittest
import uuid

from bridge.backend import ITermBackend
from bridge.protocol import (Failure, MAX_FRAME, decode, encode, sanitize, validate)
from bridge.server import BridgeServer, PrivateSocket, same_user


TARGET = {"session_id": "s1", "window_id": "w1", "tab_id": "t1", "title": "shell"}


def can_bind_unix_socket():
    with tempfile.TemporaryDirectory(prefix="gpt-probe-", dir="/tmp") as temp:
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.bind(str(Path(temp) / "probe.sock"))
            except PermissionError as exc:
                if exc.errno == errno.EPERM:
                    return False
                raise
    return True


CAN_BIND = can_bind_unix_socket()
BIND_RESTRICTION = "Sandbox denies AF_UNIX.bind; run on host to verify filesystem socket binding."


def request(operation="ping", **fields):
    base = {"version": 1, "id": str(uuid.uuid4()), "operation": operation}
    if operation not in {"ping", "capture_target"}:
        base["target"] = dict(TARGET)
    return {**base, **fields}


class Notification:
    def __init__(self, field, value):
        self.field = field
        setattr(self, field, value)

    def HasField(self, name):
        return self.field == name


class FakeSession:
    def __init__(self, session_id):
        self.session_id = session_id
        self.name = "shell"
        self.sent = []
        self.lines = ["old", "prompt"]
        self.info = NS(overflow=17, scrollback_buffer_height=1, mutable_area_height=1)
        self.transaction = False
        self.send_started = asyncio.Event()
        self.hang_send = False

    async def async_send_text(self, text, *, suppress_broadcast):
        self.sent.append((text, suppress_broadcast))
        self.send_started.set()
        if self.hang_send:
            await asyncio.Event().wait()

    async def async_get_line_info(self):
        assert self.transaction
        return self.info

    async def async_get_contents(self, first_line, number_of_lines):
        assert self.transaction
        offset = first_line - self.info.overflow
        return [NS(string=line) for line in self.lines[offset:offset + number_of_lines]]


class FakeTab:
    def __init__(self, tab_id, session):
        self.tab_id = tab_id
        self.current_session = session
        self.sessions = [session]
        self.activated = []
        self.directions = []

    async def async_activate(self, *, order_window_front):
        self.activated.append(order_window_front)

    async def async_select_pane_in_direction(self, direction):
        self.directions.append(direction)


class FakeApp:
    def __init__(self):
        self.session = FakeSession("s1")
        self.other = FakeSession("s2")
        self.tab = FakeTab("t1", self.session)
        self.other_tab = FakeTab("t2", self.other)
        self.window = NS(window_id="w1", tabs=[self.tab, self.other_tab], current_tab=self.tab)
        self.current_window = self.window
        self.windows = {"w1": self.window}
        self.sessions = {"s1": self.session, "s2": self.other}
        self.app_active = True
        self.broadcast_domains = []
        self.refreshes = 0
        self.lookups = []
        self.on_refresh = None
        self.raw_status = 1
        self.raw_window = "w1"
        self.raw_active = True
        self.raw_session = "s1"
        self.raw_tab = "t1"
        self.on_raw = None
        self.hang_refresh = False

    async def async_refresh(self):
        self.refreshes += 1
        if self.on_refresh:
            self.on_refresh()
        if self.hang_refresh:
            await asyncio.Event().wait()

    async def async_refresh_broadcast_domains(self):
        pass

    def get_session_by_id(self, session_id, *, include_buried):
        self.lookups.append((session_id, include_buried))
        return self.sessions.get(session_id)

    def get_window_by_id(self, window_id):
        return self.windows.get(window_id)

    def get_window_and_tab_for_session(self, session):
        for tab in self.window.tabs:
            if session in tab.sessions:
                return self.window, tab
        return None, None


def backend():
    app = FakeApp()

    async def focus(_):
        if app.on_raw:
            app.on_raw()
        notifications = [Notification("application_active", app.raw_active),
                         Notification("window", NS(window_id=app.raw_window, window_status=app.raw_status)),
                         Notification("selected_tab", app.raw_tab), Notification("session", app.raw_session)]
        return NS(focus_response=NS(notifications=notifications))

    class Transaction:
        def __init__(self, _):
            pass

        async def __aenter__(self):
            app.session.transaction = True

        async def __aexit__(self, *args):
            app.session.transaction = False

    statuses = NS(Value=lambda name: {"TERMINAL_WINDOW_BECAME_KEY": 1,
                                     "TERMINAL_WINDOW_IS_CURRENT": 2,
                                     "TERMINAL_WINDOW_RESIGNED_KEY": 3}[name])
    api = NS(rpc=NS(async_get_focus_info=focus), Transaction=Transaction,
             api_pb2=NS(FocusChangedNotification=NS(Window=NS(WindowStatus=statuses))),
             NavigationDirection=NS(LEFT="left", RIGHT="right", ABOVE="above", BELOW="below"))
    return ITermBackend(None, app, api)


class ProtocolTests(unittest.TestCase):
    def test_all_endpoints_and_exact_fields(self):
        variants = [("ping", {}), ("capture_target", {}), ("insert_text", {"text": "hello"}),
                    ("control", {"control": "enter"}), ("select_tab", {"tab_direction": "next"}),
                    ("select_pane", {"direction": "up"}), ("authorize_key", {"direction": "left"}),
                    ("read_scrollback", {"line_count": 40, "first_line": 17})]
        for operation, fields in variants:
            with self.subTest(operation=operation):
                valid = request(operation, **fields)
                self.assertEqual(validate(valid), valid)
                with self.assertRaises(Failure):
                    validate({**valid, "shell": "whoami"})

    def test_rejects_bad_types_nulls_bounds_and_combinations(self):
        invalid = [request(version=True), request(version=1.0), request(id="x"), request(target=TARGET),
                   request("shell"), request("control", control="\r"), request("control", control=[]),
                   request("insert_text", text=None), request("insert_text", text="x", control="enter"),
                   request("read_scrollback", line_count=True), request("read_scrollback", line_count=1.0),
                   request("read_scrollback", line_count=0), request("read_scrollback", line_count=129),
                   request("read_scrollback", line_count=1, first_line=None),
                   request("read_scrollback", line_count=1, first_line=9007199254740992),
                   request("select_tab", tab_direction="up"), request("select_pane", direction="above"),
                   request("insert_text", text="\ud800"), request("control", control="enter", target=None)]
        for value in invalid:
            with self.subTest(value=repr(value)):
                with self.assertRaises(Failure):
                    validate(value)
        with self.assertRaises(Failure) as raised:
            validate(request(version=2))
        self.assertEqual(raised.exception.code, "unsupported_version")

    def test_target_validation(self):
        for replacement in ({"session_id": ""}, {"tab_id": "a\nb"}, {"window_id": "x" * 257},
                            {"title": "é" * 513}, {"extra": "unexpected"}, {"tab_id": 1}):
            with self.subTest(replacement=replacement), self.assertRaises(Failure):
                validate(request("control", control="enter", target={**TARGET, **replacement}))

    def test_sanitizer_matches_core_without_silent_wire_changes(self):
        self.assertEqual(sanitize(" \tHi\r\n世界\x1b\x00\x1c\x7f\x80\u200b!\u2028 ok  "), "Hi 世界! ok")
        self.assertEqual(sanitize("a\x1cb"), "ab")  # Not Python's broader isspace().
        for text in ("a\nb", " a", "a ", "a\t b", "\x1b[31m", "a\u202eb", "", "a\x9bb"):
            with self.subTest(text=repr(text)), self.assertRaises(Failure):
                validate(request("insert_text", text=text))
        validate(request("insert_text", text="echo '$HOME'; enter cancel 😀"))
        validate(request("insert_text", text="é" * 4096))
        with self.assertRaises(Failure) as raised:
            validate(request("insert_text", text="é" * 4097))
        self.assertEqual(raised.exception.code, "too_large")

    def test_json_duplicates_utf8_constants_and_frame_limit(self):
        for value in (b'{"id":1,"id":2}', b'{"target":{"a":1,"a":2}}', b'\xff', b'{', b'NaN', b'Infinity'):
            with self.subTest(value=value), self.assertRaises(Failure):
                decode(value)
        with self.assertRaises(Failure):
            encode({"huge": "x" * MAX_FRAME})


class BackendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.backend = backend()
        self.app = self.backend.app

    async def assertFailure(self, req, code):
        with self.assertRaises(Failure) as raised:
            await self.backend.dispatch(req)
        self.assertEqual(raised.exception.code, code)
        self.assertEqual(self.app.session.sent, [])
        self.assertEqual(self.app.other.sent, [])

    async def test_capture_and_text_suppression(self):
        result = await self.backend.dispatch(request("capture_target"))
        self.assertEqual(result["target"], TARGET)
        self.app.broadcast_domains = [object()]
        await self.backend.dispatch(request("insert_text", text="echo hello"))
        self.assertEqual(self.app.session.sent, [("echo hello", True)])
        self.assertEqual(self.app.lookups, [("s1", False)])
        self.assertEqual(self.app.other.sent, [])
        self.assertEqual(self.app.refreshes, 2)

    async def test_every_control_suppresses_broadcast(self):
        for control in ("enter", "escape", "tab", "interrupt"):
            await self.backend.dispatch(request("control", control=control))
        self.assertEqual(self.app.session.sent, [("\r", True), ("\x1b", True), ("\t", True), ("\x03", True)])

    async def test_closed_target_never_falls_back(self):
        del self.app.sessions["s1"]
        await self.assertFailure(request("insert_text", text="danger"), "target_gone")

    async def test_target_moved_or_identity_mismatched(self):
        for key in ("window_id", "tab_id"):
            await self.assertFailure(request("control", control="enter", target={**TARGET, key: "elsewhere"}), "target_changed")
        self.app.tab.sessions.remove(self.app.session)
        self.app.other_tab.sessions.append(self.app.session)
        await self.assertFailure(request("control", control="enter"), "target_changed")

    async def test_focus_change_on_refresh_and_fresh_raw_snapshot(self):
        self.app.on_refresh = lambda: setattr(self.app.window, "current_tab", self.app.other_tab)
        self.app.raw_tab = "t2"
        self.app.raw_session = "s2"
        await self.assertFailure(request("control", control="enter"), "target_changed")
        self.app.on_refresh = None
        self.app.window.current_tab = self.app.tab
        self.app.raw_tab = "t1"
        self.app.on_raw = lambda: setattr(self.app, "raw_session", "s2")
        await self.assertFailure(request("control", control="enter"), "target_changed")

    async def test_panels_hidden_and_missing_key_focus_fail_closed_even_when_active(self):
        for status in (2, 3, None):
            self.app.raw_status = status
            await self.assertFailure(request("capture_target"), "not_focused")
        self.app.raw_status = 1
        self.app.raw_window = "closed"
        await self.assertFailure(request("capture_target"), "not_focused")

    async def test_inactive_key_hotkey_supports_tabs_voice_and_native_authorization(self):
        self.app.raw_active = False
        self.app.app_active = False
        # The SDK may remember another window or none. Only the raw key ID counts.
        for remembered in (None, NS(window_id="remembered", current_tab=self.app.other_tab)):
            self.app.current_window = remembered
            result = await self.backend.dispatch(request("capture_target"))
            self.assertEqual(result["target"], TARGET)
            await self.backend.dispatch(request("select_tab", tab_direction="next"))
            await self.backend.dispatch(request("insert_text", text="voice draft"))
            await self.backend.dispatch(request("authorize_key", direction="up"))
        self.assertEqual(self.app.other_tab.activated, [False, False])
        self.assertEqual(self.app.session.sent, [("voice draft", True)] * 2)
        self.assertEqual(self.app.other.sent, [])
        self.app.broadcast_domains = [object()]
        with self.assertRaises(Failure) as raised:
            await self.backend.dispatch(request("authorize_key", direction="up"))
        self.assertEqual(raised.exception.code, "broadcast_active")

    async def test_inactive_key_hotkey_still_requires_exact_tab_session_and_target(self):
        self.app.raw_active = self.app.app_active = False
        for attribute, value in (("raw_tab", "t2"), ("raw_session", "s2")):
            original = getattr(self.app, attribute)
            setattr(self.app, attribute, value)
            await self.assertFailure(request("insert_text", text="draft"), "target_changed")
            setattr(self.app, attribute, original)
        await self.assertFailure(request("control", control="enter", target={**TARGET, "tab_id": "t2"}),
                                 "target_changed")
        for status in (2, 3, None):
            self.app.raw_status = status
            await self.assertFailure(request("insert_text", text="draft"), "not_focused")

    async def test_tab_wrap_and_pane_mapping_return_pre_action_target(self):
        for direction in ("previous", "next"):
            result = await self.backend.dispatch(request("select_tab", tab_direction=direction))
            self.assertEqual(result["target"], TARGET)
        self.assertEqual(self.app.other_tab.activated, [False, False])
        for direction in ("up", "down", "left", "right"):
            result = await self.backend.dispatch(request("select_pane", direction=direction))
            self.assertEqual(result["target"], TARGET)
        self.assertEqual(self.app.tab.directions, ["above", "below", "left", "right"])

    async def test_key_authorization_never_injects_and_rejects_any_broadcast(self):
        result = await self.backend.dispatch(request("authorize_key", direction="up"))
        self.assertEqual(result["target"], TARGET)
        self.assertEqual(self.app.session.sent, [])
        self.app.broadcast_domains = [object()]
        await self.assertFailure(request("authorize_key", direction="up"), "broadcast_active")

    async def test_scrollback_actual_lines_bounds_and_empty_buffer(self):
        result = await self.backend.dispatch(request("read_scrollback", line_count=40))
        self.assertEqual(result["page"], {"target": TARGET, "first_line": 17, "oldest_line": 17,
                                         "newest_line": 19, "lines": ["old", "prompt"]})
        for first, expected in ((0, 17), (18, 18), (999, 19)):
            result = await self.backend.dispatch(request("read_scrollback", line_count=1, first_line=first))
            self.assertEqual(result["page"]["first_line"], expected)
            self.assertLessEqual(len(result["page"]["lines"]), 1)
        self.app.session.info.scrollback_buffer_height = 0
        self.app.session.info.mutable_area_height = 0
        result = await self.backend.dispatch(request("read_scrollback", line_count=40))
        self.assertEqual(result["page"]["lines"], [])
        self.assertEqual(result["page"]["first_line"], 17)

    async def test_scrollback_clips_utf8_and_json_escaped_budget(self):
        self.app.session.lines = ["😀" * 1024] * 128
        self.app.session.info.scrollback_buffer_height = 127
        result = await self.backend.dispatch(request("read_scrollback", line_count=128))
        self.assertLess(len(result["page"]["lines"]), 128)
        self.assertTrue(all(len(line.encode()) == 2048 for line in result["page"]["lines"]))
        self.assertLessEqual(len(encode(result)), MAX_FRAME + 4)
        self.app.session.lines = ["\x00" * 4096] * 128
        result = await self.backend.dispatch(request("read_scrollback", line_count=128))
        self.assertEqual(len(result["page"]["lines"]), 3)
        self.assertLessEqual(len(encode(result)), MAX_FRAME + 4)


class SocketTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gpt-bridge-", dir="/tmp")
        self.directory = Path(self.temp.name) / "private"
        self.backend = backend()
        self.server = BridgeServer(self.backend, self.directory, frame_timeout=0.12, operation_timeout=0.15)
        if CAN_BIND:
            await self.server.start()
        else:
            # Exercise the production stream handler over real AF_UNIX sockets
            # even in a sandbox that permits socketpair but prohibits bind.
            self.server.private.acquire()
        self.connections = []

    async def asyncTearDown(self):
        for _, writer in self.connections:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
        await self.server.close()
        self.temp.cleanup()

    async def connect(self):
        if CAN_BIND:
            pair = await asyncio.open_unix_connection(str(self.server.private.path))
        else:
            client_socket, server_socket = socket.socketpair(socket.AF_UNIX)
            client_socket.setblocking(False)
            server_socket.setblocking(False)
            server_reader, server_writer = await asyncio.open_unix_connection(sock=server_socket)
            self.server.accept(server_reader, server_writer)
            pair = await asyncio.open_unix_connection(sock=client_socket)
        self.connections.append(pair)
        return pair

    async def reply(self, reader):
        size = struct.unpack("!I", await asyncio.wait_for(reader.readexactly(4), 1))[0]
        self.assertLessEqual(size, MAX_FRAME)
        return decode(await reader.readexactly(size))

    async def send(self, pair, req):
        reader, writer = pair
        writer.write(encode(req))
        await writer.drain()
        return await self.reply(reader)

    async def test_real_socket_fragmented_capture_insert_control_and_reconnect(self):
        reader, writer = await self.connect()
        req = request("capture_target")
        frame = encode(req)
        for chunk in (frame[:1], frame[1:3], frame[3:9], frame[9:]):
            writer.write(chunk)
            await writer.drain()
            await asyncio.sleep(0)
        result = await self.reply(reader)
        self.assertEqual(result, {"version": 1, "id": req["id"], "ok": True, "target": TARGET})
        await self.send((reader, writer), request("insert_text", text="hello 😀"))
        await self.send((reader, writer), request("control", control="enter"))
        self.assertEqual(self.backend.app.session.sent, [("hello 😀", True), ("\r", True)])
        writer.close()
        await writer.wait_closed()
        await asyncio.wait_for(self.server.client, 1)
        pair = await self.connect()
        self.assertTrue((await self.send(pair, request()))["ok"])
        self.assertEqual(len(self.backend.app.session.sent), 2)

    @unittest.skipUnless(CAN_BIND, BIND_RESTRICTION)
    async def test_private_modes_peer_uid_and_second_instance(self):
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.server.private.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.directory / "bridge.lock").stat().st_mode), 0o600)
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(self.server.private.path))
            self.assertTrue(same_user(client))
        second = PrivateSocket(self.directory)
        with self.assertRaises(BlockingIOError):
            second.acquire()
        second.release()
        self.assertTrue(self.server.private.path.exists())

    async def test_real_unix_peer_uid_and_instance_lock(self):
        left, right = socket.socketpair(socket.AF_UNIX)
        with left, right:
            self.assertTrue(same_user(left))
        second = PrivateSocket(self.directory)
        with self.assertRaises(BlockingIOError):
            second.acquire()
        second.release()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.directory / "bridge.lock").stat().st_mode), 0o600)

    async def test_backend_failure_does_not_expose_text_or_replay_mutation(self):
        async def fail_send(text, *, suppress_broadcast):
            raise RuntimeError("private dictated text and internal details")

        self.backend.app.session.async_send_text = fail_send
        pair = await self.connect()
        result = await self.send(pair, request("insert_text", text="hello"))
        self.assertEqual(result["error"]["code"], "outcome_unknown")
        self.assertNotIn("private", result["error"]["message"])
        self.assertEqual(await asyncio.wait_for(pair[0].read(), 1), b"")

    async def test_disconnect_during_mutation_stops_backend(self):
        self.backend.app.session.hang_send = True
        pair = await self.connect()
        pair[1].write(encode(request("control", control="enter")))
        await pair[1].drain()
        await asyncio.wait_for(self.backend.app.session.send_started.wait(), 1)
        pair[1].close()
        await pair[1].wait_closed()
        await asyncio.wait_for(self.server.failed.wait(), 1)
        self.assertTrue(self.server.unhealthy)
        self.assertEqual(self.backend.app.session.sent, [("\r", True)])

    async def test_additional_client_is_closed(self):
        first = await self.connect()
        self.assertTrue((await self.send(first, request()))["ok"])
        reader, _ = await self.connect()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")

    async def test_invalid_schema_returns_correlated_error_without_action(self):
        pair = await self.connect()
        for req in (request(version=2), request("insert_text", text="bad\ntext"),
                    request("control", control="enter", text="unexpected"), request(operation="exec")):
            result = await self.send(pair, req)
            self.assertFalse(result["ok"])
            self.assertEqual(result["id"], req["id"])
        self.assertEqual(self.backend.app.session.sent, [])

    async def test_bad_frames_and_malformed_json_close_without_action(self):
        samples = [struct.pack("!I", 0), struct.pack("!I", MAX_FRAME + 1),
                   struct.pack("!I", 1) + b"\xff", struct.pack("!I", 1) + b"{",
                   encode([]), struct.pack("!I", 13) + b'{"a":1,"a":2}', encode(request(id="bad"))]
        for sample in samples:
            reader, writer = await self.connect()
            writer.write(sample)
            await writer.drain()
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
            task = self.server.client
            if task:
                await asyncio.wait_for(task, 1)
        self.assertEqual(self.backend.app.session.sent, [])

    async def test_truncated_and_slow_frames_have_absolute_deadline(self):
        reader, writer = await self.connect()
        writer.write(b"\x00")
        await writer.drain()
        await asyncio.sleep(0.07)
        writer.write(b"\x00")
        await writer.drain()
        # A second byte must not reset the original 120 ms deadline.
        self.assertEqual(await asyncio.wait_for(reader.read(), 0.10), b"")
        if self.server.client:
            await self.server.client
        reader, writer = await self.connect()
        writer.write(struct.pack("!I", 100) + b"partial")
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.backend.app.session.sent, [])

    async def test_pipelined_action_is_never_dispatched(self):
        self.backend.app.session.hang_send = True
        reader, writer = await self.connect()
        writer.write(encode(request("insert_text", text="one")))
        await writer.drain()
        await asyncio.wait_for(self.backend.app.session.send_started.wait(), 1)
        writer.write(encode(request("insert_text", text="two")))
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.backend.app.session.sent, [("one", True)])
        self.assertTrue(self.server.unhealthy)

    async def test_mutation_timeout_reports_outcome_unknown_and_closes(self):
        self.backend.app.session.hang_send = True
        pair = await self.connect()
        result = await self.send(pair, request("insert_text", text="only once"))
        self.assertEqual(result["error"]["code"], "outcome_unknown")
        self.assertEqual(await asyncio.wait_for(pair[0].read(), 1), b"")
        self.assertEqual(self.backend.app.session.sent, [("only once", True)])
        self.assertTrue(self.server.failed.is_set())

    async def test_pre_dispatch_timeout_reports_timeout_and_no_send(self):
        self.backend.app.hang_refresh = True
        result = await self.send(await self.connect(), request("control", control="enter"))
        self.assertEqual(result["error"]["code"], "timeout")
        self.assertEqual(self.backend.app.session.sent, [])

    async def test_socket_response_scrollback_and_focus_errors(self):
        pair = await self.connect()
        page = await self.send(pair, request("read_scrollback", line_count=40))
        self.assertEqual(page["page"]["lines"], ["old", "prompt"])
        self.backend.app.raw_status = 3
        failure = await self.send(pair, request("control", control="enter"))
        self.assertEqual(failure["error"]["code"], "not_focused")


class FilesystemTests(unittest.TestCase):
    def test_unsafe_parent_lock_and_socket_are_preserved(self):
        with tempfile.TemporaryDirectory(prefix="gpt-fs-", dir="/tmp") as temp:
            root = Path(temp)
            directory = root / "private"
            directory.mkdir(mode=0o755)
            os.chmod(directory, 0o755)
            with self.assertRaises(PermissionError):
                PrivateSocket(directory).acquire()
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)
            os.chmod(directory, 0o700)
            link = root / "link"
            link.symlink_to(directory)
            with self.assertRaises(PermissionError):
                PrivateSocket(link).acquire()
            lock = directory / "bridge.lock"
            lock.symlink_to(root / "elsewhere")
            with self.assertRaises(OSError):
                PrivateSocket(directory).acquire()
            self.assertTrue(lock.is_symlink())
            lock.unlink()
            endpoint = directory / "bridge.sock"
            endpoint.write_text("preserve me")
            with self.assertRaises(PermissionError):
                PrivateSocket(directory).acquire()
            self.assertEqual(endpoint.read_text(), "preserve me")

    @unittest.skipUnless(CAN_BIND, BIND_RESTRICTION)
    def test_stale_socket_removed_and_live_socket_preserved(self):
        with tempfile.TemporaryDirectory(prefix="gpt-fs-", dir="/tmp") as temp:
            path = Path(temp) / "bridge.sock"
            old = socket.socket(socket.AF_UNIX)
            old.bind(str(path))
            os.chmod(path, 0o600)
            old.close()
            private = PrivateSocket(temp)
            private.acquire()
            self.assertFalse(path.exists())
            private.release()
            live = socket.socket(socket.AF_UNIX)
            try:
                live.bind(str(path))
                os.chmod(path, 0o600)
                live.listen(1)
                with self.assertRaises(BlockingIOError):
                    PrivateSocket(temp).acquire()
                self.assertTrue(path.exists())
            finally:
                live.close()

    @unittest.skipUnless(CAN_BIND, BIND_RESTRICTION)
    def test_cleanup_preserves_replacement_and_lock_file(self):
        with tempfile.TemporaryDirectory(prefix="gpt-fs-", dir="/tmp") as temp:
            private = PrivateSocket(temp)
            private.acquire()
            listener = private.bind()
            # Keep the old inode allocated while replacing its directory entry.
            private.path.unlink()
            replacement = socket.socket(socket.AF_UNIX)
            try:
                replacement.bind(str(private.path))
                os.chmod(private.path, 0o600)
                private.release()
                self.assertTrue(private.path.exists())
                self.assertTrue((Path(temp) / "bridge.lock").exists())
            finally:
                listener.close()
                replacement.close()


if __name__ == "__main__":
    unittest.main()
