# Promptpad

Your terminal, controlled by gamepad and voice.

A macOS 13+ menu-bar companion for iTerm2, a DualSense controller, and reviewed
voice input. Built with Apple's GameController, AVFoundation and Speech APIs,
plus a small Python iTerm2 bridge. No downloaded Swift dependencies or paid
transcription service. The app starts disabled and does not start the bridge.

## Build and start

Requires full Xcode with its license already accepted, Python 3.10+ for tests,
and iTerm2 with its Python API runtime installed. Build from the repository root:

```sh
bash scripts/build-app.sh
```

This builds a release executable without debug symbols for the current Mac, assembles
`dist/Promptpad.app`, bundles the bridge and documentation, and verifies
an ad-hoc local signature. It neither installs nor launches the app. Set
`DEVELOPER_DIR` to select another Xcode. Build/module caches stay in `.build`.
The bundle is for local development, not notarized distribution. Re-running the
script replaces only this generated app after successful build/sign verification.

Run the bridge separately, from this repository, with iTerm2 running:

```sh
"$HOME/Library/Application Support/iTerm2/uv/venvs/3.10/bin/python3" -m bridge
```

Or run the bundled copy, without needing the source checkout:

```sh
cd "dist/Promptpad.app/Contents/Resources"
"$HOME/Library/Application Support/iTerm2/uv/venvs/3.10/bin/python3" -B -m bridge
```

`-B` prevents Python bytecode caches from modifying the signed bundle.
The existing iTerm2 runtime supplies `iterm2`; system Python alone generally
does not. If needed, explicitly enable iTerm2's Python API in its settings and
approve its API connection dialog. No script changes these settings. Wait for
`Promptpad bridge ready`. Keep that process running; Ctrl+C stops it.
Then open `dist/Promptpad.app` in Finder, or run:

```sh
open "dist/Promptpad.app"
```

The setup window opens on launch. Use it (or the 🎮 menu) to enable the controller, select a microphone, and explicitly
run **Set up Microphone & Speech permissions…**. Use **Set up Accessibility for
arrows…** and allow Promptpad in System Settings → Privacy & Security →
Accessibility for D-pad arrow injection. Microphone and Speech Recognition have
their own entries there. These prompts are user setup steps, never build steps.
Close the setup window when ready; reopen the app from Finder to show it again.
Focus an iTerm2 terminal pane before operating controls. Other applications and
nonterminal windows fail focus checks. Close in-window search/composer fields
before using API controls, which act on the focused session. Native arrows require a
recognizable terminal Accessibility element and no active iTerm broadcast domain.

The Control+Escape floating iTerm2 hotkey window uses the same controls, including
L1/R1 navigation between its own tabs. Enable Accessibility for Promptpad:
floating hotkey panels can own keyboard focus while another app remains frontmost,
so the companion needs Accessibility to identify the focused terminal. Keep the
hotkey window open through recording, review, and X (×) insertion. Hiding it or
changing panes cancels an uninserted draft. The transcript appears above the hotkey
window and does not take keyboard focus.

Pair DualSense with macOS over Bluetooth (hold Create + PS until the light bar
flashes, then select it in Bluetooth settings), or connect a data-capable USB
cable. Background monitoring lets iTerm2 retain keyboard focus. Disconnects and
disabling controls cancel voice/repeat state; release held controls before reuse.

## Controls

| Control | Action |
| --- | --- |
| L1 / R1 | Previous / next tab, wrapping |
| D-pad | Native arrow keys; Accessibility permission required |
| L2 + D-pad | Adjacent split pane |
| X (×) | Enter; during voice review insert; a separate press submits |
| Circle (○) | Escape; during voice work cancel locally |
| Square (□) | Tab |
| L2 + Circle | Ctrl+C; during voice work cancel locally |
| Triangle (△) | Toggle read-only scrollback overlay |
| Left stick Y | Page scrollback, or scroll a long transcript/help overlay |
| Options | Toggle mapping/help overlay (no session picker) |
| R2 held | Dictate; release to transcribe and review |

Only arrows, tab/pane navigation and overlay scrolling repeat: after 0.4 seconds,
at most 8 times/second, with no catch-up or queued repeats during IO. Stick dead
zone is ±0.25; triggers press at 0.65 and release at 0.35. Enter, Ctrl+C, Tab,
Escape and toggles never repeat. All unrelated terminal actions are suppressed
during dictation. X (×) or Circle in scrollback closes the overlay and consumes
the press. Triangle also closes it. The overlay reads actual iTerm buffer text;
it does **not** scroll iTerm's viewport or send Page Up/wheel events to programs.
It is a plain-text viewer pinned to one session, not a terminal emulator.

## Voice and safety behavior

Use any input exposed by macOS, such as the Mac microphone, AirPods or a USB mic.
The DualSense built-in microphone is unsupported on Mac. A selected missing input
fails instead of silently switching devices. Apple Speech uses the current
locale and may send audio to Apple servers depending on language/device; offline
processing is not guaranteed. Recording is limited to 60 seconds and final
transcription to 15 seconds. Availability, network and language support vary.

Hold R2 in the intended terminal, speak, release, and review the overlay showing
the pinned terminal title. X (×) inserts sanitized text **without Enter**.
Release and press X (×) again to submit. Circle discards an uninserted draft;
after insertion it ends the workflow but cannot undo text already sent. Switching
focus/session, closing a target, disconnecting, disabling, or bridge failure
discards pending voice work. A draft is never moved to another session. Complete recording, review and
insertion in the same iTerm2 pane before returning to another application.

Transcript controls and invisible format characters are removed and whitespace
is collapsed to spaces, so CR/LF cannot submit. Shell metacharacters remain:
review the text before choosing to execute it. Speech words never become control
actions. Text and explicit controls always use iTerm's broadcast suppression;
arrows fail closed if broadcasting is active. Native arrow preflight and delivery
are not atomic with OS focus changes, so live focus-race testing is still needed.

The private socket is `/tmp/promptpad-<uid>/bridge.sock` (directory 0700,
socket 0600); one app and bridge instance are permitted. No shell-execution,
clipboard or dictated-text logging endpoint exists. After an uncertain mutation,
inspect the named terminal before acknowledging the menu error; the action is
never retried. Restart a failed bridge manually; fresh connections never replay
actions. See [bridge details](bridge/README.md) and the
[protocol contract](Sources/PromptpadCore/CONTRACT.md).

## If no transcript window appears

Open setup to inspect the controller and bridge status. The R2 diagnostic shows
its peak value and press count; squeezing it fully should reach about 100%.
It also remembers which app was frontmost at the last press. Use Command-Tab to
select the actual iTerm2 application before dictating. The companion setup
window and embedded terminals in other applications do not pass that check.

Every overlay has a **Close** button and a title-bar close control. Closing a
voice preview cancels pending dictation; text already inserted stays in the terminal.
Closing an error hides the popup but keeps controls paused until you acknowledge
the error in Setup. An error overlay also has an **Open Setup…** button. Complete any missing microphone
or speech permission setup, inspect the terminal, and acknowledge the error
before retrying. Rebuilding the development app can require authorizing it again.

## Rebuilds and permissions

### Upgrading from Gamepad Terminal

Quit the old companion and stop its bridge before starting Promptpad. Rebuild
with `bash scripts/build-app.sh`, then start the bridge and
`dist/Promptpad.app` using the commands above. Both components must be updated:
Promptpad uses `/tmp/promptpad-<uid>/bridge.sock` and bundle ID `local.promptpad`.
Grant Microphone, Speech Recognition, and Accessibility access to Promptpad
through Setup; the old app's grants do not transfer to the new bundle identity.

Quit the companion before rebuilding. Keep the bundle at a stable path when
testing. Ad-hoc signatures change with executable changes, so macOS may forget
or retain stale Microphone, Speech Recognition or Accessibility authorization.
Remove/re-add the rebuilt app in Accessibility and re-run explicit setup if
necessary. If permissions remain stuck, a user can intentionally reset only this
bundle's grants and then reopen it and authorize again:

```sh
tccutil reset Microphone local.promptpad
tccutil reset SpeechRecognition local.promptpad
tccutil reset Accessibility local.promptpad
```

These commands are troubleshooting steps, not part of build/start scripts.

## Verification

Current local validation: 78 Swift tests and 33 Python tests pass; the release
bundle builds and passes signature verification. Before the Promptpad rename,
live checks confirmed the setup window, DualSense detection, bridge connection,
permission setup, L1/R1 tab
switching, R2 transcription, and X inserting reviewed text without submission.
The successful voice test explicitly selected MacBook Pro Microphone.
Control+Escape tab switching and voice insertion were also confirmed,
including terminal focus while another application remains active. These live
results apply to the previous app identity; repeat them after granting Promptpad
its permissions. Keep the
intended terminal pane focused through recording, Review and X (×) insertion;
changing the target cancels the dictation. Native arrows and overlay mouse
dismissal remain manual checks.


```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
python3 -m unittest discover -s bridge/tests
bash scripts/build-app.sh
```

`--disable-sandbox` avoids nesting SwiftPM's sandbox inside a restricted host
sandbox; the package has no downloaded dependencies or build plugins.

Swift tests include the real Swift socket client talking to the production Python
server/dispatcher with fake iTerm sessions over an inherited Unix socketpair.
They cover fragmented response framing, UTF-8, pinned sanitized insertion with
broadcast suppression and no implicit Enter, target refusal, scrollback, and an
oversized frame closing without dispatch. No live terminal is mutated. Python
tests cover strict schemas, filesystem security, deadlines and backend behavior;
socket-binding tests explicitly skip if a sandbox prohibits bind.

Further manual checks remain: native arrow delivery, split-pane navigation,
scrollback paging in real terminal programs, separate submission, reconnects,
permission denial/revocation, focus races, broadcast rejection and other desired
microphones. Automated tests do not establish every hardware or OS behavior.
