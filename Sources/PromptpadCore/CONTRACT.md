# Shared implementation contract (protocol 1)

This file and the public Swift declarations in this directory are the contract
for the bridge, voice, controller/app, and packaging workers. No runtime bridge,
UI, or native injection is implemented by the core. Import `PromptpadCore`.
The manifest builds the library and tests alone; when the app worker creates
`Sources/PromptpadApp`, it also exposes executable product
`Promptpad`. The native voice implementation lives in the separate PromptpadVoice target.
There are no downloaded Swift dependencies. Deployment target: macOS 13.

## Supported terminal strategy

Inspected the installed Python source at
`~/Library/Application Support/iTerm2/uv/venvs/3.10/lib/python3.10/site-packages/iterm2`:

- `Session.async_send_text(self, text: str, suppress_broadcast: bool = False)`.
  Every call MUST explicitly pass `suppress_broadcast=True`.
- `Session.async_activate(self, select_tab=True, order_window_front=True)`.
  Do not use this to recover a voice target or steal focus. Voice target changes
  fail instead of activating a different/current pane.
- `Tab.async_activate(self, order_window_front=True)` and `Window.tabs` support
  previous/next tab selection in the captured window. Use `False` for ordering.
  Wrap at either end; selecting a tab is a deliberate navigation action.
- `Tab.async_select_pane_in_direction(self, direction: NavigationDirection)`;
  values are `LEFT`, `RIGHT`, `ABOVE`, `BELOW`. Map wire up/down to ABOVE/BELOW.
- `App.async_refresh()` refreshes topology and focus;
  `App.async_refresh_focus()` alone refreshes focus.
  Resolve the candidate with `app.get_window_by_id` using the fresh key-window ID.
  `current_window` remembers a terminal even after a non-terminal iTerm window
  becomes key. `app.app_active` is not required: floating hotkey panels become
  key without activating iTerm2.
- `iterm2.rpc.async_get_focus_info(connection)` returns
  `response.focus_response.notifications`. Inspect fresh raw window statuses;
  require `TERMINAL_WINDOW_BECAME_KEY` for the candidate window. Reject
  `TERMINAL_WINDOW_IS_CURRENT` and `TERMINAL_WINDOW_RESIGNED_KEY`. Fail closed
  when the fresh snapshot does not establish a terminal key window. The App
  wrapper deliberately drops resigned-key information; do not rely on it here.
- `App.get_session_by_id(session_id, include_buried=False)` is exact lookup.
  Verify its window/tab IDs too. Never fall back to `current_session`.
- `App.async_refresh_broadcast_domains()` and `App.broadcast_domains` can
  establish whether native key injection would broadcast.
- No generic session send-key API was found. Arrows therefore use native
  `CGEvent(keyboardEventSource:virtualKey:keyDown:)` down/up, posted to the
  verified iTerm process with `postToPid`. Carbon virtual key constants
  `kVK_LeftArrow`, `kVK_RightArrow`, `kVK_UpArrow`, `kVK_DownArrow` avoid magic
  keycodes. Do not generate terminal arrow escape sequences or infer cursor mode.
  Require explicit Accessibility permission (`AXIsProcessTrustedWithOptions`),
  system-wide keyboard-focused bundle `com.googlecode.iterm2`, and focused terminal
  content rather than a search/settings/sheet text field. The app must freshly
  call `authorize_key` for the exact target and direction and immediately recheck
  native foreground/focus before posting. Expire authorization after 100 ms
  measured from request start. Reject any active broadcast domain; never change
  the user's broadcast settings. Authorization is one-use and never cached.
  OS focus and event delivery are not atomic with Python RPC: runtime permission,
  focus-race, keyboard-profile and hardware testing remains necessary. Do not
  describe this as a guaranteed atomic targeted key API.
- Enter, Tab, Escape, and Ctrl+C are explicit `control` operations sent directly
  to the captured session with broadcast suppression. Their only accepted byte
  strings are respectively `"\r"`, `"\t"`, `"\u001b"`, `"\u0003"`. These are
  deliberate terminal control characters, not transcript or arrow encodings.
  No endpoint accepts caller-supplied arbitrary control bytes.

### Real scrollback, with an honest UI adjustment

Triangle toggles a **read-only scrollback overlay**. The vertical stick pages
through actual iTerm buffer contents; this does not move iTerm's own viewport.
Never send Page Up or wheel events to the terminal process and call it scrollback
(wheel events may become mouse reports in full-screen applications).

The supported installed APIs are
`Session.async_get_line_info() -> SessionLineInfo` and
`Session.async_get_contents(first_line: int, number_of_lines: int) -> list[LineContents]`.
Read both inside `async with iterm2.Transaction(connection)` to avoid a buffer
overflow race. `LineContents.string` contains the text. Set `oldest_line` to
`info.overflow` and exclusive `newest_line` to
`overflow + scrollback_buffer_height + mutable_area_height`. Clamp requested
`first_line` into the available range. When omitted, return the newest page.
Return at most the requested line_count (1...128), clip each line to 2048 UTF-8
bytes without splitting a scalar, and cap total encoded JSON response to 65536
bytes. Use a 48000-byte budget for line strings *after JSON escaping*; return
fewer lines when necessary. A caller advances by the actual returned line count.
Empty buffers may return an empty page with first_line == newest_line.
This is plain-text viewing, not terminal emulation; render as inert text.

The app pins the overlay to the first captured target until Triangle exits;
positive stick Y requests older lines, negative Y newer lines. Initial request
omits first_line. Subsequent requests use `max(oldest_line, first_line - delta)`.
If focus/target changes, close the overlay and report the target change; do not
silently switch its session. Close it on gate loss or voice start. Cross in
scroll mode must close the viewer and consume that press, rather than send Enter.
Circle also closes/consumes; ordinary Circle outside the viewer sends Escape.
Options shows local help (a session picker is optional, not a required endpoint).

## IPC transport

- AF_UNIX stream, exactly `/tmp/promptpad-<getuid()>/bridge.sock` on both
  sides. `BridgeProtocol.socketPath(userID:)` is the Swift authority. Do not use
  NSTemporaryDirectory or Python tempfile defaults, which differ by process.
- Parent directory owned by current UID, mode 0700. Socket owner current UID,
  mode 0600. Both sides lstat and reject symlinks, wrong types, owners, or modes;
  never chmod an untrusted existing directory. Set umask 077 before creation.
  Verify peer UID where available. This protects against other users, not code
  already running as the same user.
- Hold an exclusive nonblocking flock on `app.lock` and `bridge.lock` in the
  private directory for each process lifetime. Check lock file owner/type/mode
  and open with O_NOFOLLOW. Never unlink these lock files while running.
  The bridge may remove a stale socket only after taking its instance lock and
  verifying the entry is an owned socket. Never unlink arbitrary files or a
  live other instance's socket. Clean up the bridge's socket on normal shutdown.
- Each frame: **4-byte unsigned big-endian payload length**, then exactly that
  many bytes of UTF-8 JSON. Length 1...65536 inclusive. No newline delimiter.
  `BridgeProtocol.encode` includes the header; `BridgeFrameDecoder.append`
  returns payloads without headers, supports fragmented/coalesced frames, and
  `finish()` rejects truncated data. Any framing error closes the connection.
- Strict object schema below. Reject unknown operation, enum, or request field,
  malformed JSON/UTF-8, duplicate JSON keys, booleans/floats in integer fields,
  unknown version and wrong field combinations. Optional means omitted, not null.
  `BridgeRequest.validate()` verifies typed field combinations and bounds;
  the Python JSON decoder must also validate the raw object strictly, before
  constructing/dispatching an action. Untrusted response IDs and fields must be
  validated with `BridgeResponse.validate(for:)` before use.
- At most one accepted app client, one outstanding request on its stream, and
  one iTerm action at a time globally. No pipelining or event stream. Additional
  clients/requests fail busy or are closed without running an action. The app
  drops navigation repeats while busy, and never buffers stale held controls.
  Actor isolation alone does not serialize calls across an await; use an explicit
  in-flight guard/serial runner. Do not hold the UI actor in blocking socket IO.
- Absolute deadlines: connect 1 s, complete frame read/write 2 s, iTerm operation
  2 s, end-to-end client request 3 s from start. Slow reads must not reset the
  frame deadline on each byte. Validate the prefix before allocating payload.
  On timeout/cancellation close the stream so a late response cannot match a
  new request. An expired mutation may already have executed: surface
  outcome_unknown, block controller actions until user acknowledgment, and ask
  the user to inspect that target. Do not retry the mutation.
- Use UUID request IDs. IDs correlate replies; they are **not** exactly-once
  deduplication tokens. Reconnect only on a fresh socket: bounded exponential
  delays 0.25, 0.5, 1, 2, 4, then 5 s maximum; one pending reconnect, cancellation
  stops it. Reconnect/ping while enabled is fine; never queue/replay a text,
  control, navigation, or native-key action across reconnect. Gate loss cancels
  the voice generation. Require a new physical edge after reconnect.
- No shell execution, command evaluation, clipboard, log of dictated text, or
  automatic speech-to-command conversion endpoint.

## JSON schema and examples

Required request keys: `version:1`, `id:UUID-string`, `operation:string`.
`target` is required except for ping/capture_target, where it is forbidden.
A target has exactly `session_id`, `window_id`, `tab_id`, `title` strings.
IDs are nonempty, <=256 UTF-8 bytes, without C0 or DEL; title <=1024 bytes.
Target title is display-only; use all three IDs for identity.

| operation | Additional required keys | Optional keys | Result |
| --- | --- | --- | --- |
| ping | none | none | no target/page |
| capture_target | none | none | current verified target |
| insert_text | text | none | original target |
| control | control: enter/escape/tab/interrupt | none | original target |
| select_tab | tab_direction: previous/next | none | original acted-on target |
| select_pane | direction: left/right/up/down | none | original acted-on target |
| authorize_key | direction: left/right/up/down | none | original target; never injects itself |
| read_scrollback | line_count: 1...128 | first_line: 0...9007199254740991 | target + page |

Every operation except ping requires a fresh verified **terminal key
window**. Before acting, refresh topology, resolve exact target (not buried),
verify all three IDs and that it is the current terminal session. Return
target_gone if missing; target_changed if moved or a different session is focused;
not_focused if the app/key-terminal gate is closed. Do not activate the voice
target to satisfy the gate. Return the **pre-action target** for tab/pane changes,
because that identifies where the deliberate navigation began.

Success response: required `version`, matching `id`, `ok:true`; `target` required
except ping; `page` required only for read_scrollback. Error response: required
`version`, `id`, `ok:false`, `error:{code,message}`, no target/page. Error messages
<=1024 UTF-8 bytes. When no valid ID can be recovered (e.g. malformed framing),
close instead of inventing an ID. Codes are the raw values of BridgeErrorCode:
invalid_request, unsupported_version, too_large, timeout, disconnected,
unavailable, busy, not_focused, target_gone, target_changed, broadcast_active,
permission_denied, stale_generation, outcome_unknown, internal_error.

Examples below are JSON payloads; prepend their actual UTF-8 byte lengths,
not character counts, as the four-byte header:

```json
{"version":1,"id":"00000000-0000-0000-0000-000000000001","operation":"capture_target"}
{"version":1,"id":"00000000-0000-0000-0000-000000000001","ok":true,"target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"}}
{"version":1,"id":"00000000-0000-0000-0000-000000000002","operation":"insert_text","target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"text":"echo hello"}
{"version":1,"id":"00000000-0000-0000-0000-000000000003","operation":"control","target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"control":"enter"}
{"version":1,"id":"00000000-0000-0000-0000-000000000004","operation":"authorize_key","target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"direction":"up"}
{"version":1,"id":"00000000-0000-0000-0000-000000000005","operation":"read_scrollback","target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"line_count":40}
{"version":1,"id":"00000000-0000-0000-0000-000000000005","ok":true,"target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"page":{"target":{"session_id":"s1","window_id":"w1","tab_id":"t1","title":"shell"},"first_line":17,"oldest_line":17,"newest_line":19,"lines":["actual old output","prompt"]}}
{"version":1,"id":"00000000-0000-0000-0000-000000000006","ok":false,"error":{"code":"target_gone","message":"The captured session closed. Start a new dictation in the intended session."}}
```

`insert_text` accepts only nonempty **already sanitized** text <=8192 UTF-8 bytes.
Swift review uses `TranscriptSanitizer.validated`; the bridge independently
verifies the same policy. Do not silently transform a malicious wire request.
Normalize every whitespace/newline run to one ASCII space, trim ends, drop
C0/C1 controls and Unicode category Cf. Preserve other printable Unicode.
Whitespace is exactly Unicode White_Space: U+0009...000D, 0020, 0085, 00A0,
1680, 2000...200A, 2028, 2029, 202F, 205F, 3000. Drop Cf first, normalize those
whitespace scalars second, drop remaining Cc third. Do not use Python isspace()
alone (it also considers U+001C...001F whitespace).
This removes CR/LF/TAB/ESC and prevents implicit submission. It does not escape
shell metacharacters: the user reviews text and separately chooses to execute it.
Speech never becomes control, regardless of words such as "enter" or "cancel".

## Swift interfaces and orchestration

- `TerminalTarget`, `TerminalAction`, `Direction`, `TabDirection`,
  `TerminalControl`, `ScrollbackPage`, `BridgeStatus`: `Interfaces.swift`.
- `BridgeClient: Sendable`: `request(BridgeRequest) async throws -> BridgeResponse`,
  `disconnect() async`. Implement in app target using a private serial IO runner;
  validate request before sending and response before returning.
- `@MainActor VoiceService: AnyObject`: `inputs:[AudioInput]`,
  `recognitionNotice:String`, `requestAuthorization() async throws`,
  `startRecording(inputID:String?, generation:UInt64) async throws`,
  `stopAndTranscribe(generation:UInt64) async throws -> String`,
  `cancel(generation:UInt64)`. Cancellation only cancels the matching generation,
  releases microphone/resources, and invalidates late recognition callbacks.
  Honor an explicitly selected audio input or fail; never silently substitute.
  Bound recording to 60 s and final recognition wait to 15 s; surface errors.
  Permissions may be requested via explicit setup; no recording starts until
  enabled, connected, frontmost, and target captured. Cancel a start that returns
  after its generation was invalidated. Never assume Apple Speech is offline.
- `@MainActor ControllerEventSource`: `onEvent:((ControllerEvent)->Void)?`,
  `start()`, `stop()`. Native adapter enables background monitoring, emits
  buttons/triggers/stick and monotonic tick events; the pure mapper maps them.
  Connection changes go to `ApplicationEvent.controllerConnected` separately.
- `@MainActor NativeKeyService`: `sendArrow(Direction,target:TerminalTarget)
  async throws`. The implementation performs the fresh bridge preflight and
  native focus/permission checks described above. No generalized key injection.
- `ApplicationState.handle(ApplicationEvent) -> [ApplicationEffect]` is the
  pure authoritative reducer. Public read-only status supports the menu/overlay.
  Feed callback completions with their original generation. Never read the
  current generation to label an old callback. Effects have explicit generations
  and exact pinned targets where relevant. Execute terminal effects with a fresh
  capture + verified action; stale generations/gates abort before every side
  effect and after every await. Process cancellation immediately even if another
  effect is awaiting IO; do not put cancel behind a long transcription task.
  Guard noncancellable async start/recognition results on both sides of an await.

Voice flow: idle -> capturingTarget -> startingRecording -> recording ->
transcribing -> review -> inserting -> inserted -> submitting -> idle.
R2 release before target capture cancels; release during async audio start stops
as soon as recording has started. Review Cross inserts safe text into the pinned
target without Enter. Only a **new Cross press after insertion completion** sends
Enter to the same target. Repeated Cross while inserting/submitting is ignored.
Circle (including L2+Circle) cancels locally during voice work. After insertion,
Circle ends the workflow but does not delete already inserted text. All other
terminal/navigation input is ignored throughout non-idle voice states.

Disable, disconnect, bridge loss, foreground loss, and errors increment the
cancellation generation and discard the pending workflow. Never resume it on
reconnect or retarget it. A closed/changed target is an error; a draft is not
reinserted elsewhere. Errors require an explicit UI `dismissError` acknowledgment
before controller actions resume; especially after an ambiguous mutation, tell
the user to inspect the named target. Stale callbacks cannot clear a newer error
or resurrect a recording. Cancel cannot undo bytes already delivered to iTerm.

After each reducer event call `mapper.setGate(state.canUseTerminal)` and
`mapper.setOrdinaryActionsEnabled(state.acceptsOrdinaryActions)`, then
`mapper.setScrollMode(state.scrollMode)`. Observe scrollMode becoming false to
close the viewer; its initial true event emits scrollback(deltaLines: 0).
Keep feeding
all physical release events while gated so held inputs never become new edges.
On disconnect also call `mapper.disconnected()`; require R2/button release on
reconnect. The adapter should feed a complete current input snapshot at connection
so controls that are already released are rearmed immediately.
Do not hide voice completion behind the input gate. Publish view state on the
main actor. Keep dictation/scrollback overlays nonactivating so the terminal keeps
keyboard focus, including nonactivating hotkey panels. If a UI actually takes
focus, obey foreground cancellation.

Mapping: L1/R1 previous/next tab; D-pad arrows; L2+D-pad adjacent pane;
Cross Enter/voice confirm; Circle Escape/local cancel; Square Tab;
L2+Circle Ctrl+C; Triangle scrollback overlay; stick Y pages overlay;
Options help; R2 hold dictate. Mapper hysteresis: trigger press >=0.65,
release <=0.35; stick dead zone |Y|<=0.25; repeat delay 0.4 s then at most
8 Hz, one event per tick with no catch-up. Only arrows, pane/tab navigation,
and overlay scroll repeat. Enter, Ctrl+C, Tab, Escape and mode toggles never
repeat. Drop repeats during IO and clear them on voice start/gate loss.

## Verification and environment

Core tests cover C0/C1/format/newline sanitization, byte limits, schema field
separation, fragmented/coalesced/oversized/truncated frames, response IDs/targets,
scrollback bounds, voice target pinning, separate insert/submit, stale callback
rejection, quick trigger release, cancellation, focus gates, trigger hysteresis,
dead zones, bounded repeat and no repeated Enter/Ctrl+C. Runtime bridge, socket
interop, permissions, actual native arrows and physical audio/controller tests
belong to the dependent implementations/integration.

The Command Line Tools compiler builds the core, but its installation does not
expose XCTest by default. Use full Xcode's test framework/runner when necessary;
do not accept licenses or change developer settings as part of this assignment.
Use temporary/local module and SwiftPM caches in the restricted environment.
The successful validation uses `swift test` with temporary cache paths; 20 XCTest
cases execute (the separate Swift Testing runner has no tests).

An available native implementation route for selectable audio is
`AVCaptureDeviceInput(device:)` + `AVCaptureAudioDataOutput`, feeding
`SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer(_:)`. These
signatures, the DualSense cast/background monitoring, AX focus lookup and
CGEvent creation/postToPid were verified by compiling a typecheck-only native
API probe. The probe did not invoke any of those APIs or request permissions.

Source reference for menu API constraints (no scrollback-page menu endpoint):
https://iterm2.com/python-api/menu_ids.html. Native API evidence was read from
installed CoreGraphics, HIServices and GameController SDK headers. No menu ID or
escape-sequence scrolling behavior is inferred from those headers.

Physical R2 release closes the audio gate synchronously, before waiting on bridge IO.
Release during capture startup cancels that generation; late startup completion cannot revive it.
