# 2026-09-29: Wrong assumptions about permissions, reopening and launch signals

## Summary
While validating spec 001 on a real Mac, four assumptions from the design turned out to be wrong. One of them, how the app learns that Screen Recording was granted or revoked, needed a redesign of the permission tracking. All were found by running the quickstart, none by the unit tests, because each depends on how macOS really behaves.

## Impact
- The "Restart required" state could never appear, so a user who granted the permission was not told to relaunch (FR-011).
- A permission revoked while the app ran was never noticed (spec edge case), so the menu kept claiming it was granted.
- A second launch, or a click in Finder, did not open Settings (FR-014).
- Caught before any user relied on it; no data was involved. Cost: about four rounds of manual testing.

## Timeline
- Spike R5 concluded that a relaunch is needed after granting, and that `CGPreflightScreenCaptureAccess()` did not flip in the running process. The design then still expected to detect the grant from the process's own reading.
- Manual validation: enabling the permission left the window on "Not granted". The log showed no status change for over a minute.
- First fix: ask a freshly started copy of the app (`--probe-permission`) while a status window is open. "Restart required" then appeared, but the status flapped every 2 seconds because the process's own stale reading undid it.
- Second fix: the in-process reading stopped counting once in `restartRequired`. Then `tccutil reset` on the running app showed revocation was never noticed either.
- Final design: after launch the permission is followed only by fresh-process probes, every 2 seconds.
- Separately: a second launch did not show Settings, first because the notification never left the exiting process, then because Finder on a running app sends a "reopen" event rather than starting a second copy.
- Review afterwards: "lowest PID wins" for single instance is unsafe because PIDs wrap (they wrapped during this very session); an unpinned package version; a probe without a timeout.

## Root cause
Assumptions taken from documentation and reasoning instead of from observation:
1. **A running process can see permission changes.** It cannot. macOS gives it the answer it had at launch, in both directions. Only a new process sees the current state.
2. **The spike outcome was enough.** The spike proved a relaunch is needed, but not how the app would find out; that second question was never asked.
3. **A second launch means a second process.** Clicking an app that is already running sends a reopen event to it instead. Both cases must be handled.
4. **A process can post a notification and quit.** A distributed notification is only handed to the system from a running run loop; quitting straight after posting loses it.
5. **A lower PID means an older process.** PIDs wrap.
6. **Xcode runs a build script before it validates signing.** It validates the identity first, so the friendly message has to come from a scheme pre-action.

## Fix
- Permission tracking is probe-only after launch (`PermissionMonitor.observeFreshProcess`, tests first). The capture path reads the tracked status.
- The app handles the reopen event and the second-launch signal (run loop kept turning before exit); the oldest copy wins (`SingleInstanceArbiter`, launch date, PID only as a tie-break); relaunch waits for the old process to exit.
- The probe has a 2 second timeout; the KeyboardShortcuts version is pinned exactly.
- Notes are in `specs/001-menubar-shell/research.md` (R3, R5, R6, R7) and `data-model.md`.

## Gotchas worth remembering
- A probe started from a terminal is attributed to the terminal, not to Memorri, so it always says `denied`. Only a probe started by the app itself is meaningful.
- In zsh, `log` is a shell built-in. Use `/usr/bin/log stream …`. A `log stream` redirected to a file can stay empty because of buffering; use `log show` afterwards.
- `NSLock` cannot be used inside `async` functions in Swift 6; put the locking in a synchronous helper.
- `tccutil reset ScreenCapture com.aletc1.memorri` revokes the permission from a script, which makes revocation testable.

## Follow-ups
- [ ] Spec 002: the tracked permission status is advisory. The real ScreenCaptureKit capture call is the source of truth, and a failed capture must change the status and open onboarding.
- [ ] Decide whether the always-on probe (a short-lived process every 2 seconds, about 20 ms and 1 ms of CPU each) is acceptable long term, or should run only while a status window is open, plus on app activation and capture requests.
- [ ] Spec 010 (hardening): consider a lighter probe, for example a tiny helper tool in the app bundle.
