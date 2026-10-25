# Gamepad Terminal — implementation brief

Build a usable macOS menu-bar companion for controlling iTerm2 with a PS5
DualSense controller. Voice fills in the text that buttons cannot. The user
authorized implementation and explicitly requested agent orchestration.

## Product behavior

- Pair the DualSense over Bluetooth or USB using macOS. Read it through Apple's
  GameController framework. Enable background controller monitoring because
  iTerm2, rather than the companion, owns the foreground window.
- Gate terminal actions to iTerm2 being frontmost, handle controller disconnects,
  and apply dead zones and bounded repeat rates. Never auto-repeat Enter or Ctrl+C.
- Starting mapping: L1/R1 previous/next tab; L2+D-pad adjacent split pane;
  D-pad arrows; Cross Enter/confirm; Circle Escape/cancel; Square Tab;
  Triangle scroll mode; stick scrolls in scroll mode; L2+Circle Ctrl+C;
  Options session picker/help; R2 hold to dictate. Adjust mappings if a concrete
  native API constraint requires it, and document the final mapping honestly.
- Capture any selectable macOS audio input. Sony explicitly does not support
  the controller's built-in microphone on Mac; use the Mac, AirPods, or USB mic.
- Hold R2, speak, release, review a transcript overlay, Cross inserts without
  submitting; a separate Cross submits. Circle discards an uninserted draft.
  Recording and transcription must not accidentally send other buttons through.
- Pin dictation to the exact session ID captured at recording start. Never fall
  back to a newly focused session if it closes or focus changes. Show the target.
- Treat dictated text as text: remove terminal control characters and normalize
  newlines so insertion cannot implicitly submit. Do not execute/transmute speech
  into commands automatically. Disable iTerm2 broadcast for all sent text.
- Show controller, bridge, and recording state and actionable errors. Avoid
  interfering with other applications or recording while disabled/disconnected.
- A minimal working implementation with clear setup is preferable to speculative
  features. No controller hardware or spoken audio is guaranteed during testing.

## Architecture and evidence already gathered

- Empty Git workspace, no commits yet; do not commit or push. Existing .cs,
  .claude and local session files belong to the user and must be preserved.
- macOS 26.7.1 arm64; Swift 6.3.3 installed; Xcode available.
- iTerm2 installed at /Applications/iTerm.app. EnableAPIServer is already 1.
- Use a Swift package, native AppKit/SwiftUI menu-bar app and GameController,
  AVFoundation + Speech; a Python iTerm2 bridge; no paid transcription API.
  Speech recognition may use Apple servers depending on locale/device: label
  that accurately; do not claim it is invariably offline.
- Prefer a private Unix-domain socket with a 0700 parent directory and 0600
  socket over an unauthenticated TCP listener. Length-limit and time-limit
  messages, serialize actions, clean up on exit/reconnect. No shell execution
  endpoint. A single companion instance and bridge instance should be enforced.
- Python runtime already available under:
  ~/Library/Application Support/iTerm2/uv/venvs/3.10/bin/python3
  API source under the corresponding lib/python3.10/site-packages/iterm2.
  Inspect it to establish exact available API signatures before implementation.
- Verified APIs: app.current_window, window.current_tab, tab.current_session;
  app.async_refresh_focus(), app.app_active; session.async_activate();
  tab.async_select_pane_in_direction(NavigationDirection); session.async_send_text
  (text, suppress_broadcast=True); iterm2.MainMenu.async_select_menu_item.
- iTerm2's app.current_window remembers the last terminal even when another
  iTerm2 panel is key: account for focus rather than assuming it is safe.
- iTerm2 Python API does not expose a generic send-key method in inspected
  session.py. Terminal escape sequences need application-cursor-mode awareness.
  Native key injection is an alternative where needed, with an explicit
  Accessibility permission and focus gating. Do not promise scrollback if the
  implementation only sends Page Up into the foreground terminal process.
- Useful docs: https://iterm2.com/python-api/ and its menu_ids.html;
  Apple GCDualSenseGamepad and GCController.shouldMonitorBackgroundEvents docs.

## Deliverables and acceptance

- Sources/, Package.swift, Tests/ for the native app and testable core.
- bridge/ with the Python bridge and meaningful unittest tests in bridge/tests/.
- Resources/Info.plist with microphone/speech usage descriptions; scripts/ with
  a reproducible build-app.sh producing dist/Gamepad Terminal.app. Ad-hoc signing
  is acceptable for local development; explain permission resets on rebuilds.
- Install/start instructions and a controller mapping table in README.md.
  Build and verify before any installation. Do not silently edit system/iTerm
  preferences or install LaunchAgents. No downloads needed for Swift packages.
- Acceptance commands: swift test; python3 -m unittest discover -s bridge/tests;
  bash scripts/build-app.sh. Use repository/temp-local caches when necessary.
- Test session targeting, broadcast suppression, malformed input/oversized IPC,
  safe text insertion, focus gating, repeat behavior and disconnect cancellation
  where feasible. Test actual socket interoperability, not just mocks, if feasible.
- Independent review must inspect concrete code and build/test evidence. Fix
  significant findings. Report hardware/permission checks that remain manual.

## Orchestration constraints

Use a short dependency graph with explicit ownership: API/core contract first,
controller/app, bridge, voice, packaging/tests, independent review. Independent
reads may run together; writes run serially. Every writer must know others share
the worktree and preserve their work. Workers do not commit, push, spawn other
agents, install apps, or change machine settings. Keep findings/artifacts bounded.
