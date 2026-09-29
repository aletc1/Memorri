# Research: Menu-bar shell, hotkey and permissions

Each item: Decision, Rationale, Alternatives considered. Items marked **Verify** are assumptions that the first tasks must prove on this Mac before more code is built on them.

## R1. Menu-bar UI: SwiftUI `MenuBarExtra`, `.menu` style

- **Decision**: Use `MenuBarExtra` with the menu style. The icon is a template image; a "flash" swaps to a highlighted variant for about 300 ms from observable state.
- **Rationale**: Native, minimal code, matches ADR 0002. Menu style gives standard menu behaviour, including keyboard use.
- **Alternatives**: `NSStatusItem` in AppKit (more control over the button and flash animation, more code). Fall back to it only if the label cannot update reliably. **Verify** in the first UI task that the label image changes on state change.

## R2. Windows: AppKit `WindowCoordinator` hosting SwiftUI views

- **Decision**: One `WindowCoordinator` keeps one `NSWindow` (with an `NSHostingController`) per window kind (settings, onboarding, inbox, search) and shows or fronts it on request.
- **Rationale**: The hotkey, a capture without permission and a second launch all need to open a window from outside any SwiftUI view. The SwiftUI `openWindow` action only exists inside a view, and a menu-bar-only app has no always-present view. The SwiftUI `Settings` scene is also awkward for agent apps. A coordinator gives one instance per window by construction (spec User Story 4, scenario 3).
- **Alternatives**: SwiftUI `Window` scenes plus `openWindow` (needs a hidden host view, fragile). SwiftUI `Settings` scene (not reliable to open from code in an agent app).
- **Detail**: the app runs with `LSUIElement = YES`. Before showing a window, call `NSApp.activate()` so it comes to the front.

## R3. Global hotkey: KeyboardShortcuts package

- **Decision**: Use `KeyboardShortcuts`, name `capture`, initial value Control+Option+Command+M (ADR 0008). Handle key-up events.
- **Rationale**: Registers a system-wide hotkey without requiring Accessibility or Input Monitoring permission, persists the choice, and ships a recorder that already refuses shortcuts taken by the system or the app's main menu.
- **Alternatives**: Raw Carbon `RegisterEventHotKey` (what the package wraps, more code). A CGEvent tap (needs Input Monitoring, and would let the app read all typing; rejected on privacy grounds).
- **Verify**: (a) the package's own checks, and whether it refuses a shortcut with no modifier; the spec requires this (FR-007). If it does not, `ShortcutValidator` in the core enforces it before the shortcut is saved. (b) The initial value is applied on a clean install. (c) Behaviour with a full-screen remote-desktop client (see R8).

## R4. Shortcut validation rules (FR-007)

- **Decision**: `ShortcutValidator` in `MemorriCore` decides accept or reject with a reason: no modifier key, already used by another Memorri action, or reported as a system shortcut. The system-shortcut check is delegated to a protocol `SystemShortcutChecking`; the app adapter uses the package's own check.
- **Rationale**: The rules are testable without UI, and the spec's "keep the previous shortcut" behaviour needs one place that decides. The recorder is used with a binding, so the app saves a shortcut only after the validator accepts it.
- **Alternatives**: Rely entirely on the package recorder (no control over the no-modifier rule and the "explain which rule" message). Reject only after saving and then revert (flashes an invalid state).

## R5. Screen Recording permission: check without capturing

- **Decision**: `CGPreflightScreenCaptureAccess()` gives the status. `CGRequestScreenCaptureAccess()` shows the system prompt once. The status is re-read every 2 seconds while a window that shows it is open, and when the app becomes active. The deep link is `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
- **Rationale**: No capture is needed in this spec, so no screen content is read. Polling is cheap and covers both "granted" and "revoked while running" (edge case).
- **Restart required**: macOS sometimes reports granted only for processes started after the grant. The state machine treats "not granted at launch, then reported granted while running" as `restartRequired` and offers a relaunch, which is the safe reading. **Verify** on macOS 26 whether a relaunch is actually needed; if not, the state collapses to `granted` and FR-011 becomes a no-op branch.
- **Alternatives**: Try a ScreenCaptureKit capture to detect permission (reads screen content, needs the permission it is testing, and may show the prompt again). Use the newer picker-based capture (does not fit a hotkey flow).

## R6. Single instance and second-launch signal

- **Decision**: At launch, `NSRunningApplication.runningApplications(withBundleIdentifier:)` is checked for other processes. If one exists, the new process posts a `DistributedNotificationCenter` notification `com.aletc1.memorri.openSettings` and terminates. The running instance listens and opens Settings.
- **Rationale**: Simple, no sockets or files, works without extra permissions, and covers FR-014.
- **Alternatives**: A lock file (no way to signal the first instance). XPC or a local socket (more moving parts, and a socket is at odds with the "no network" rule in spirit).
- **Edge**: the check ignores its own PID; two near-simultaneous launches can both see the other, so the one with the higher PID exits.

## R7. Signing and the permission surviving rebuilds (FR-015)

- **Decision**: `project.yml` sets manual signing with identity `Memorri Local`, no team, hardened runtime off, no sandbox entitlement. A pre-build shell phase, `scripts/check-signing-identity.sh`, runs `security find-identity -v -p codesigning` and fails with a message that names `scripts/create-signing-certificate.sh` if the identity is missing.
- **Rationale**: macOS keys the Screen Recording grant to the app's code requirement. A stable certificate keeps that requirement identical across rebuilds; ad-hoc signing changes it each time (ADR 0007). The pre-build check turns Xcode's vague signing failure into an actionable message.
- **Alternatives**: Ad-hoc signing (permission lost each build). An Apple development certificate (requires an Apple account and team; not needed for local-only use).
- **Verify**: after the first build, run `codesign -dr - <app>` twice across a rebuild and confirm the requirement is identical (quickstart step).

## R8. Hotkey inside a full-screen remote-desktop client

- **Decision**: Treat as a manual acceptance test with the user's real client. Design mitigations up front: configurable shortcut (done), menu-bar fallback (done), and document in the quickstart what to try if the client swallows the key.
- **Rationale**: Some clients grab the keyboard in full-screen so that shortcuts go to the remote session instead of macOS. This cannot be simulated, and the registered system hotkey may or may not be seen first.
- **Verify**: on the real client, with the default shortcut and one alternative, and record the result in the quickstart's results table. If both fail, write a postmortem or an ADR (for example a "capture via menu-bar click only" workflow) before spec 002.

## R9. Capture request recording and feedback

- **Decision**: `CaptureRequestService` in the core accepts a trigger (menu or shortcut), ignores a second request within 300 ms of the first (debounce), stores the request in an in-memory ring buffer (last 100) and logs it with `os.Logger` (subsystem `com.aletc1.memorri`, category `capture`). It calls a `FeedbackPlaying` protocol; the app adapter flashes the icon and plays the sound, each only if enabled.
- **Rationale**: Testable in the core, observable from outside with `log stream` for the manual tests (SC-002 counts log lines), and no persistence is needed until spec 002.
- **Alternatives**: Write to a file (extra cleanup and privacy surface). Store in a database (spec 002).
- **Sound**: `NSSound` with a system sound name (for example "Pop"); no bundled audio file.

## R10. Permission for feedback

- **Decision**: No notification permission is requested (clarification 1). Nothing in this spec asks for Calendar, Reminders, Accessibility, Input Monitoring or network access.

## R11. Bundle identifier and defaults keys

- **Decision**: Bundle identifier `com.aletc1.memorri`; log subsystem the same. `UserDefaults` keys are prefixed `memorri.` and listed in the [UI contract](contracts/ui-contract.md).
- **Rationale**: A fixed identifier is part of the code requirement that the permission is bound to, so it must not change after the first grant.

## R12. Testing approach

- **Decision**: Swift Testing for core logic (validator, debounce, permission state machine, settings). Fakes for every protocol. UI, hotkey delivery, permission flow and rebuild persistence are manual, using [quickstart.md](quickstart.md) with a results table.
- **Rationale**: Menu-bar UI automation is brittle and the two hardest acceptance criteria (remote-desktop hotkey, TCC persistence) cannot be automated anyway.
- **Alternatives**: XCUITest for the menu (can drive menu-bar items but adds a test host and slows every change). Deferred until the UI is larger.
