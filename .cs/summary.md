# Promptpad — session summary

## 2026-10-25 rename

The project and GitHub repository are now **Promptpad**:
https://github.com/Gherghi67/promptpad. Current source targets use `Promptpad*`,
the bundle is `dist/Promptpad.app` with ID `local.promptpad`, and the bridge uses
`/tmp/promptpad-<uid>/bridge.sock`. `~/Documents/promptpad` is a symlink to the
original checkout, whose real path is required by the active Codex sandbox.
The renamed app needs fresh macOS permission grants. Details below record the
pre-rename wrap and retain historical paths and observations.

## Gamepad Terminal — wrapped 2026-10-25

## 1. Objective

Complete the native macOS DualSense/iTerm2 companion, extend working normal-window controls and reviewed voice insertion to the user's Control+Escape floating hotkey terminal, then publish to personal GitHub and wrap.

## 2. Environment

- Worktree: `/Users/bogdan.gherghina/Documents/gamepad-terminal`; branch `main`.
- Private remote: https://github.com/Gherghi67/gamepad-terminal (`origin`). Personal identity: `gherghinabogdan7@gmail.com`; narrative actor: `gherghinabogdan7-gmail-com`. The personal repository was created directly and source plus wrap artifacts were pushed. The user rejected the transfer approach; the user has taken responsibility for manually deleting the mistakenly created work-account copy.
- macOS arm64, iTerm2 3.7.6, full Xcode toolchain. Swift package uses AppKit, GameController, AVFoundation and Speech; Python bridge uses the installed iTerm2 Python environment.
- Working bundle: `dist/Gamepad Terminal.app`, bundle ID `local.gamepad-terminal`; generated bundle/caches are ignored. Companion and bridge were left running with controls enabled, DualSense connected, and MacBook Pro Microphone selected. Recheck runtime state before launching duplicates.

## 3. Key Discoveries

- Floating hotkey terminals can be key while Discord/Slack remains the active application. Use fresh raw terminal-key window identity and system-wide accessibility focus, not remembered current windows or active-app identity alone.
- Real iTerm terminal accessibility content is AXTextArea labelled `shell`. The earlier mocked “terminal” label missed the native mismatch.
- Ad-hoc rebuilds can invalidate grants even while System Settings shows On. User explicitly approved re-adding this app's Accessibility entry and resetting only its Microphone/Speech Recognition grants. Hidden consent alerts were found manually on another Space/display; both grants then verified.
- Keep the exact window/tab/session focused until review and insertion finish. A recorded failure was a target change during recording; it latched controls until acknowledgment. The earlier generic Apple Speech failure was not conclusively attributed. Passive R2 traces showed stable long holds; do not claim a proven trigger defect.

## 4. Changes Made

- Added the native controller app, pure state/mapping core, bounded Unix-socket bridge, Apple voice pipeline, tests, packaging and setup documentation during this task lineage.
- This continuation corrected bridge hotkey routing and AX focus recognition, preserved strict native-arrow gating, and bounded AX messaging latency.
- Semantic target failures now cancel local workflows without treating them as transport loss. Losing a target after confirmed insertion ends tracking without replaying text; uncertain-send errors remain latched.
- Preview uses a nonactivating panel above floating hotkey windows with Close/Open Setup; Close hides errors without unlocking controls. PS5 confirmation is labelled X (×). Setup retains useful metadata-only diagnostics.
- Initially pushed source to the active work account by mistake. At the user’s correction, created a new private `Gherghi67/gamepad-terminal` directly and pushed source plus wrap artifacts. The user authorized deleting the mistaken work copy; CLI deletion lacks the delete_repo scope; the user elected to delete the work copy manually. Personal publication and wrap are complete. Saved durable native-focus/permission findings and this wrap summary; rotate the configured narrative through `cs`, not manual archival.

## 5. Key Files & Outputs

- `README.md`: build/setup, mappings, permission troubleshooting, verified scope.
- `Sources/GamepadTerminalApp/{AppCoordinator,NativeKeys,MenuBarApp,SetupWindow}.swift`: coordination, focus, UI.
- `Sources/GamepadTerminalVoice/`: capture and recognition lifecycle.
- `Sources/GamepadTerminalCore/CONTRACT.md`: protocol and behavioral invariants.
- `bridge/backend.py`, `bridge/server.py`, `bridge/tests/`: exact target routing and bounded IPC.
- `.cs/memory/project_native_focus_and_permissions.md`: durable implementation/consent facts.
- `.cs/handoffs/2026-10-25-support-ctrl-escape-terminal-tabs.md`: detailed chronological evidence. Its earliest runtime/Git notes are historical; final appended success and this summary supersede them.
- Local verification artifacts: `/tmp/gamepad-terminal-shell-focus-tests.log`, `...-build.log`, `...-review.log`; `/tmp/gamepad-terminal-hotkey-python.log`. Temporary passive diagnostic probes were stopped.

## 6. Outcome

Completed and live-confirmed by the user: L1/R1 switch native Control+Escape tabs; R2 hold → speak → release → Review → X (×) once inserts text. Normal-window voice insertion had also been confirmed earlier. The successful hotkey test kept mouse/keyboard untouched through insertion.

Validation: 78 Swift tests and 33 Python tests passed; the host Python run had no socket skips and treated ResourceWarning as an error. Release bundle built and passed strict signature verification. Independent configured Codex reviews found no supported remaining P1/P2 in their reviewed scope. Publishing and wrapping changed documentation/Git state only, so no rebuild was needed.

## 7. Notes for Future Reference

- Preserve the currently working signed bundle and grants. Rebuild only for a concrete code change.
- Do not inspect/open the companion while the user performs the full voice workflow: changing focus can cancel its pinned draft.
- Do not claim all manual behavior is verified. Native arrows, actual split-pane navigation, overlay mouse dismissal, scrollback, separate submission, disconnect/reconnect and broader race/stress checks remain outside the confirmed hotkey workflow.
- CUA refused iTerm GUI automation and protected UserNotificationCenter access. Do not bypass those boundaries; use permitted integration reads and user-driven hardware/consent checks.
- Plain `$wrap` was requested. No continuation task, task archival, app shutdown, or additional permission reset is requested.

Personal narrative: `.cs/memory/narrative.gherghinabogdan7-gmail-com.md`. The user explicitly corrected the account/email during wrap; this supersedes older work-account references in the chronological handoff.
