---
name: native-focus-and-development-permissions
description: iTerm hotkey focus semantics, native accessibility identity, and development-build consent pitfalls.
type: project
---

# Native focus and development permissions

- iTerm2 floating hotkey windows can own keyboard focus while another application remains active. Resolve the fresh raw TERMINAL_WINDOW_BECAME_KEY window ID; neither NSWorkspace's active application nor the SDK's remembered current window is sufficient. Preserve exact window/tab/session pinning and reject nonterminal focus.
- iTerm2 3.7.6 exposes terminal content as AXTextArea with accessibility label `shell`. Requiring a description containing only `terminal` rejected real hotkey panes; tests must include the actual `shell` label with another app active.
- Rebuilding the ad-hoc-signed app can invalidate stored grants while System Settings still displays Accessibility as On. Confirm permission in the running app. Stabilize code and build once before repairing grants; documentation-only changes do not require rebuilding the working bundle.
- Microphone and Speech Recognition prompts can be hidden on another Space/display. In this session the user found and approved them manually after an authorized app-specific reset; TCC metadata confirmed both grants. Do not mistake an invisible prompt for a missing request or repeat resets blindly.
- Keep the same terminal target focused through hold, release, Review, and X (×) insertion. A changed target cancels an uninserted draft; acknowledgment is necessary after a latched error. Never acknowledge an uncertain send merely to enable a retry.

Evidence: Sources/PromptpadApp/NativeKeys.swift, bridge/backend.py, and .cs/handoffs/2026-10-25-support-ctrl-escape-terminal-tabs.md. Live hotkey tabs and voice insertion were both confirmed on 2026-10-25.
