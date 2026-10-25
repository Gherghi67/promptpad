---
name: session-narrative-gherghinabogdan7-gmail-com
description: Session lab-notebook and work-in-progress narrative for gherghinabogdan7-gmail-com. Looser bar than durable memory. Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs/narrative-archive/.
type: narrative
---
# Session narrative (gherghinabogdan7-gmail-com)

## 2026-10-25 — Control+Escape support completed and published

- Implemented fresh raw iTerm key-window routing, system-wide AX terminal recognition (including iTerm's actual `shell` label), target-lifecycle handling, and a nonactivating preview with Close/Open Setup. Preserve exact target pins, broadcast suppression, explicit review, synchronous microphone stop on release, and uncertain-send latching.
- Validation: 78 Swift tests and 33 Python tests passed; host Python run had no skipped socket tests and treated ResourceWarning as error. Signed release bundle verified. Independent configured Codex reviews found no supported remaining P1/P2 in the reviewed changes.
- Live user confirmation: L1/R1 switch native Control+Escape tabs; R2 hold→speak→release→Review→X (×) inserts text. MacBook Pro Microphone selected. The working companion/bridge were left running unchanged.
- Permission troubleshooting required explicitly authorized re-add of only this app's Accessibility entry and reset of only its Microphone/SpeechRecognition grants. User located hidden consent alerts and allowed them; both grants verified. Later generic recognition failure remains unattributed; another attempt was cancelled by a changed terminal target. Final uninterrupted workflow succeeded without another rebuild.
- Passive trigger/focus probes were temporary and are stopped. No terminal content or dictated text was logged by those probes. Remaining broader manual checks include native arrows, overlay mouse dismissal, and stress/focus races.
- User then requested personal GitHub publication followed by wrap. Initially created a private repository under the active bogdan-gherghina account and pushed source commit 81ab7ea; user corrected the destination to Gherghi67 and email to gherghinabogdan7@gmail.com. The user subsequently rejected the transfer approach. Created a new private https://github.com/Gherghi67/gamepad-terminal directly and pushed source plus wrap artifacts. Generated app/caches and machine-local session files remain ignored. Wrap saved durable memory and .cs/summary.md; narrative rotation reported nothing to rotate (2 KB against a 128 KB budget). Wrap artifacts were committed with the personal author identity and pushed to the newly created personal repository.

- Personal identity correction: repository-local Git email and CS actor now use gherghinabogdan7@gmail.com; narrative moved to narrative.gherghinabogdan7-gmail-com.md with its index and local context updated. No global Git email changed.

- Cleanup remains pending: the user explicitly authorized deleting bogdan-gherghina/gamepad-terminal, but its CLI token lacks delete_repo scope. Browser has only the personal session; attempted saved work sign-in was rejected. Asked user to sign in to the work account or delete that mistaken repository themselves. The user subsequently said “I will delete it manually”; deletion is now a user-owned follow-up, not unfinished agent work. Personal publication and wrap are complete; do not claim the work copy was deleted.


## 2026-10-25 — Renamed to Promptpad

- User selected Promptpad and explicitly requested updating the project and repository. Renamed app UI, Swift package/products/modules/source and test directories, executable, bundle identity (`local.promptpad`), bridge socket (`/tmp/promptpad-<uid>/bridge.sock`), build script, and current documentation. Historical handoffs retain their original observations.
- Renamed the same GitHub repository (ID 1433609229) to https://github.com/Gherghi67/promptpad, updated description and origin. GitHub reported the repository was already public before this work; visibility was not changed.
- `~/Documents/promptpad` is a symlink to the original real checkout `~/Documents/gamepad-terminal`. A real directory move was attempted, but Codex rejects a symlinked writable root; restored the real original path to keep this session functional. A physical folder/session rename requires doing it outside this active sandbox session.
- Validation: all 78 Swift tests and 33 Python tests passed (host socket access; Python ResourceWarning treated as error). Release build, plist checks and strict signature verification passed. Verified source/test contents differ only by name substitution and the bundled README matches source. Logs: `/tmp/promptpad-swift-tests.log`, `/tmp/promptpad-python-tests.log`, `/tmp/promptpad-build.log`.
- Quit the old companion and stopped the verified old bridge. Preserved the old generated app in a temporary `promptpad-previous-app-*` directory. Started the new bundled bridge (exec session 21201; PID 31035 observed) and Promptpad (PID 31090 observed). Bridge printed ready on `/tmp/promptpad-501/bridge.sock`. UI inspection showed `Promptpad — Setup`, controls disabled, system default microphone. No new macOS permission grants were made; the user must grant Microphone, Speech Recognition, and Accessibility for this new bundle identity and reselect their microphone before live testing. Prior identity's hardware checks are historical, not verification of the renamed app.
