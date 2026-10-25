"""The only iTerm2 actions exposed by the bridge. All targets fail closed."""

from .protocol import (CONTROLS, MAX_LINE, Failure, json_bytes, success,
                       validate_target)


def clipped(text, limit):
    return text.encode("utf-8")[:limit].decode("utf-8", errors="ignore")


class ITermBackend:
    def __init__(self, connection, app, api):
        self.connection = connection
        self.app = app
        self.api = api
        self.mutation_started = False

    async def focused(self, expected=None):
        await self.app.async_refresh()
        raw = await self.api.rpc.async_get_focus_info(self.connection)
        key_window = None
        selected_tabs = set()
        active_sessions = set()
        # Do not reuse App.current_window's remembered terminal-key state.
        # A current-but-not-key terminal means an iTerm panel owns keyboard input.
        statuses = self.api.api_pb2.FocusChangedNotification.Window.WindowStatus
        became_key = statuses.Value("TERMINAL_WINDOW_BECAME_KEY")
        for notification in raw.focus_response.notifications:
            if notification.HasField("window"):
                window = notification.window
                if window.window_status == became_key:
                    key_window = window.window_id
                elif key_window == window.window_id:
                    key_window = None
            elif notification.HasField("selected_tab"):
                selected_tabs.add(notification.selected_tab)
            elif notification.HasField("session"):
                active_sessions.add(notification.session)
        # Floating hotkey panels can be key without activating the application.
        # Resolve the fresh key identity, never the SDK's remembered current window.
        window = self.app.get_window_by_id(key_window) if key_window else None
        tab = window.current_tab if window else None
        current = tab.current_session if tab else None
        if not current or key_window != window.window_id:
            raise Failure("not_focused", "Focus an iTerm2 terminal window before using the controller.")
        if tab.tab_id not in selected_tabs or current.session_id not in active_sessions:
            raise Failure("target_changed", "Terminal focus changed during verification. Start again.")
        if expected is not None:
            session = self.app.get_session_by_id(expected["session_id"], include_buried=False)
            if session is None:
                raise Failure("target_gone", "The captured session closed. Start again in the intended session.")
            owner, owner_tab = self.app.get_window_and_tab_for_session(session)
            if (owner is None or owner_tab is None or owner.window_id != expected["window_id"]
                    or owner_tab.tab_id != expected["tab_id"] or current.session_id != session.session_id
                    or window.window_id != owner.window_id or tab.tab_id != owner_tab.tab_id):
                raise Failure("target_changed", "The captured session or terminal focus changed. Start again.")
        else:
            session = current
        target = {"session_id": session.session_id, "window_id": window.window_id,
                  "tab_id": tab.tab_id, "title": clipped(session.name, 1024)}
        validate_target(target)
        return window, tab, session, target

    async def dispatch(self, request):
        self.mutation_started = False
        operation = request["operation"]
        if operation == "ping":
            # Test connectivity without requiring foreground focus.
            await self.api.rpc.async_get_focus_info(self.connection)
            return success(request)
        if operation == "authorize_key":
            await self.app.async_refresh_broadcast_domains()
            if self.app.broadcast_domains:
                raise Failure("broadcast_active", "Turn off iTerm2 broadcast before using native arrow keys.")
        window, tab, session, target = await self.focused(request.get("target"))
        if operation == "insert_text":
            self.mutation_started = True
            await session.async_send_text(request["text"], suppress_broadcast=True)
        elif operation == "control":
            self.mutation_started = True
            await session.async_send_text(CONTROLS[request["control"]], suppress_broadcast=True)
        elif operation == "select_tab":
            tabs = window.tabs
            index = next(i for i, candidate in enumerate(tabs) if candidate.tab_id == tab.tab_id)
            step = 1 if request["tab_direction"] == "next" else -1
            self.mutation_started = True
            await tabs[(index + step) % len(tabs)].async_activate(order_window_front=False)
        elif operation == "select_pane":
            direction = {"left": "LEFT", "right": "RIGHT", "up": "ABOVE", "down": "BELOW"}[request["direction"]]
            self.mutation_started = True
            await tab.async_select_pane_in_direction(getattr(self.api.NavigationDirection, direction))
        elif operation == "read_scrollback":
            page = await self.read_page(session, target, request)
            return success(request, target=target, page=page)
        return success(request, target=target)

    async def read_page(self, session, target, request):
        async with self.api.Transaction(self.connection):
            info = await session.async_get_line_info()
            oldest = info.overflow
            newest = oldest + info.scrollback_buffer_height + info.mutable_area_height
            if not 0 <= oldest <= newest <= MAX_LINE:
                raise Failure("unavailable", "iTerm2 returned invalid buffer bounds.")
            first = max(oldest, min(request.get("first_line", newest - request["line_count"]), newest))
            count = min(request["line_count"], newest - first)
            contents = await session.async_get_contents(first, count) if count else []
        lines = []
        budget = 48000
        for line in contents[:count]:
            text = clipped(line.string, 2048)
            size = len(json_bytes(text)) + 1  # Include JSON quotes, escaping and comma.
            if size > budget:
                break
            budget -= size
            lines.append(text)
        return {"target": target, "first_line": first, "oldest_line": oldest,
                "newest_line": newest, "lines": lines}
