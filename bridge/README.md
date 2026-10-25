# iTerm2 bridge

From the repository root, with iTerm2 running and its Python API enabled:

```sh
"$HOME/Library/Application Support/iTerm2/uv/venvs/3.10/bin/python3" -m bridge
```

The installed iTerm2 runtime supplies the only nonstandard dependency. Launching
may show iTerm2's API authorization dialog. This program does not edit settings,
install anything, inject native keys, or launch shell commands. Leave it running
alongside the companion; Ctrl+C or SIGTERM shuts it down and removes its socket.
When packaging, keep the `bridge` package directory together and set its parent
as the working directory or Python module search path before invoking `-m bridge`.

The companion connects to `/tmp/promptpad-<getuid()>/bridge.sock`, using
the version 1 contract in `Sources/PromptpadCore/CONTRACT.md`. Frames have
a four-byte unsigned big-endian UTF-8 JSON byte length (1...65536), followed by
the JSON payload. One client and one outstanding request are allowed. There is
no request replay, action queue, subscription, or arbitrary command endpoint.
Only `ping`, `capture_target`, `insert_text`, `control`, `select_tab`,
`select_pane`, `authorize_key`, and `read_scrollback` are accepted.

Each operation except ping refreshes topology and checks a fresh raw focus
snapshot. A remembered current terminal under an iTerm settings/search panel
does not pass the terminal-key-window check. Targeted actions resolve the exact
non-buried session and verify its window, tab, and current focus; a closed or
changed target fails. `authorize_key` checks broadcast domains and never posts
events: the companion must separately enforce its 100 ms authorization lifetime,
Accessibility permission, keyboard-focus PID, and focused terminal-content checks.
The fresh key-window ID determines the candidate window; a remembered
`App.current_window` is insufficient. A floating hotkey panel can be key while
`application_active` is false, so application activation is not a prerequisite.
The native companion independently checks keyboard focus for that case.
Text/control sends always explicitly suppress broadcast. Dictated text must
already match the core sanitizer; unsafe wire text is rejected without sending.
Tab/pane navigation returns the original target. Scrollback returns actual
buffer lines as inert text, with transaction-protected reads and JSON byte limits.

The directory is owner-only 0700, the socket 0600, and `bridge.lock` is held with
nonblocking flock for the listening bridge lifetime. Existing entries must have
the expected owner, type and mode. Symlinks are rejected. A stale owned socket
is removed only after taking the lock and proving no listener accepts it;
cleanup checks the socket inode before unlinking. Lock files are kept in place.
macOS `LOCAL_PEERCRED` and Linux `SO_PEERCRED` verify connecting peer UIDs.

Normal client disconnects permit a fresh connection. Truncated, oversized,
malformed, slow, or pipelined streams are closed. Complete frame reads/writes
have two-second absolute deadlines, iTerm operations two seconds, and server
request processing three seconds from the first frame byte. An RPC failure,
timeout, or disconnect during an action poisons that backend and stops the
bridge; an issued mutation can return `outcome_unknown` and is never retried.
Inspect the named terminal and restart the bridge after acknowledging that
condition in the companion. The companion owns bounded reconnection backoff
and must not replay actions or reuse native-key authorizations. Idle API loss
is detected by the next request/ping. There is no automatic iTerm API reconnect.

Run tests with either system Python 3.10+ or iTerm2's runtime:

```sh
python3 -m unittest discover -s bridge/tests
```

Tests use a fake iTerm backend and real Unix sockets. If a sandbox rejects Unix
socket binding with EPERM, transport tests use real AF_UNIX socketpairs instead;
three path-binding/lifecycle tests explicitly skip and must run on the host.
The suite covers exact targeting, closed/moved targets, raw focus changes and
iTerm panels, broadcast suppression, control bytes, defensive text validation,
strict schemas and JSON, fragmented/truncated/oversized IPC, frame deadlines,
single-client dispatch, disconnects, timeout ambiguity and actual scrollback.
No test sends text to live terminals. Live focus races, native arrows and
permission behavior still require the companion's integration/manual checks.

API evidence: implementation inspected the installed `iterm2/app.py`
(`async_get_app`, refresh, exact lookup, window/tab lookup, current focus,
broadcast domains), `session.py` (IDs/name, text send, line info/contents),
`window.py` (IDs/tabs/current tab), `tab.py` (IDs/current session, activation,
pane navigation and NavigationDirection), `rpc.py` (raw focus),
`transaction.py`, `screen.py` (line string), and `connection.py`
(`run_until_complete`). Protobuf focus statuses are read from the installed
`api_pb2.FocusChangedNotification.Window.WindowStatus` declaration at runtime.
