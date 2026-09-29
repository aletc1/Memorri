---

description: "Task list for spec 001: menu-bar shell, hotkey and permissions"
---

# Tasks: Menu-bar shell, hotkey and permissions

**Input**: Design documents from `/specs/001-menubar-shell/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. UI and system behaviour are checked with the quickstart scenarios.

**Organization**: Grouped by user story. Paths follow the layout in plan.md (`App/`, `Packages/MemorriCore/`, `scripts/`, `project.yml`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 menu and capture request, US2 global hotkey, US3 permission onboarding, US4 Settings skeleton and single instance
- Commands assume the repository root as the working directory.

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: An empty but buildable app and package, signed with the stable local identity.

**Precondition**: `scripts/create-signing-certificate.sh` has been run (`security find-identity -v -p codesigning` lists "Memorri Local").

- [x] T001 Create `Packages/MemorriCore/Package.swift` (swift-tools-version 6.2, platform macOS 26, one library target `MemorriCore`, one test target `MemorriCoreTests` using Swift Testing) with folders `Sources/MemorriCore/{Capture,Lifecycle,Permissions,Shortcuts,Settings}` and one placeholder test in `Packages/MemorriCore/Tests/MemorriCoreTests/SmokeTests.swift`; run `swift test --package-path Packages/MemorriCore` and confirm it passes
- [x] T002 Create `scripts/check-signing-identity.sh` (executable): runs `security find-identity -v -p codesigning`, exits 0 if "Memorri Local" is listed, otherwise prints a message that names `scripts/create-signing-certificate.sh` and exits 1 (FR-015)
- [x] T003 Create `project.yml` for XcodeGen: app target `Memorri` (macOS 26.0 deployment, sources `App/`), bundle id `com.aletc1.memorri`, Info.plist properties `LSUIElement: true` and `CFBundleName: Memorri`, Swift 6 language mode, local package `MemorriCore` at `Packages/MemorriCore`, remote package `KeyboardShortcuts` (github `sindresorhus/KeyboardShortcuts`, `from:` the latest 2.x release; note the resolved version under R3 in `specs/001-menubar-shell/research.md`), manual signing with `CODE_SIGN_IDENTITY: "Memorri Local"`, no team, no sandbox entitlement, hardened runtime off, and a pre-build script phase that runs `scripts/check-signing-identity.sh`
- [x] T004 [P] Create `App/Resources/Assets.xcassets` with template image sets `MenuBarIcon` and `MenuBarIconFlash` (simple monochrome symbol drawn as PDF or PNG at 1x/2x; the flash variant is visibly heavier)
- [x] T005 Create a minimal `App/MemorriApp.swift` (`@main` app with a `MenuBarExtra` showing `MenuBarIcon` and a single "Quit Memorri" item) so that `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build` succeeds and the icon appears with no Dock icon
- [x] T006 Verify research R7 on this Mac: build twice, run `codesign -dr - .build/xcode/Build/Products/Debug/Memorri.app` after each, confirm the requirement text is identical, and record the outcome under R7 in `specs/001-menubar-shell/research.md`; also confirm that renaming the identity in `project.yml` makes the build fail with the T002 message, then restore it
### Spikes (prove the assumptions on this Mac before building on them)

- [x] T007 Spike R1 in the minimal app from T005: flip the `MenuBarExtra` label between `MenuBarIcon` and `MenuBarIconFlash` from a timer, confirm the icon really changes; if it does not, switch to an `NSStatusItem` in `App/MemorriApp.swift` and `App/AppDelegate.swift`; record the outcome under R1 in `specs/001-menubar-shell/research.md`
- [x] T008 Spike R5 in the minimal app: show `CGPreflightScreenCaptureAccess()` in the menu, remove and re-grant Screen Recording in System Settings while the app runs, and note whether the status changes without a relaunch; record the outcome under R5 in `specs/001-menubar-shell/research.md` and, if no relaunch is needed, change the `notGranted` → `restartRequired` row of `specs/001-menubar-shell/data-model.md` to `notGranted` → `granted` before Phase 2 starts
- [x] T009 Spike R3 in the minimal app: add `KeyboardShortcuts` with the name `capture` (initial Control+Option+Command+M) and a recorder; on a clean defaults domain (`defaults delete com.aletc1.memorri`) confirm the default is active, check whether the recorder alone refuses a shortcut with no modifier, and confirm it refuses a system shortcut such as Command+Space; record the outcome and the resolved package version under R3 in `specs/001-menubar-shell/research.md`, then remove the spike code

**Checkpoint**: The app builds, launches as a bare menu-bar item, signing is stable, and the R1, R3 and R5 outcomes are recorded in `research.md` before Phase 2 starts.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Types every story needs: settings, the permission monitor and the window coordinator.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T010 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SettingsTests.swift` for `CaptureFeedbackSettings`: `flashIcon` and `playSound` both default to `true` when the store is empty; setting a value is read back; keys are exactly `memorri.feedback.flashIcon` and `memorri.feedback.playSound`; uses an in-memory fake `SettingsStore`
- [x] T011 [P] Write failing tests, following the R5 outcome recorded by the spike (if a relaunch is not needed, drop `restartRequired` from these tests), in `Packages/MemorriCore/Tests/MemorriCoreTests/PermissionMonitorTests.swift` covering every row of the transition table in `data-model.md`: launch granted → `granted`; launch not granted → `notGranted`; `notGranted` then reported granted while running → `restartRequired`; `granted` then reported not granted → `notGranted`; `restartRequired` then reported not granted → `notGranted`; a fresh monitor started after a grant → `granted`; `statusUpdates()` emits each change once; uses a fake `ScreenRecordingChecking`
- [x] T012 Implement the `SettingsStore` protocol, `CaptureFeedbackSettings` (defaults `true`, keys as in T010) and `UserDefaultsSettingsStore` in `Packages/MemorriCore/Sources/MemorriCore/Settings/CaptureFeedbackSettings.swift` and `.../Settings/SettingsStore.swift`; T010 passes
- [x] T013 Implement `ScreenRecordingStatus` (`granted`, `notGranted`, `restartRequired`), `ScreenRecordingChecking` and the `PermissionMonitor` actor (init, `status`, `refresh()`, `statusUpdates()`) in `Packages/MemorriCore/Sources/MemorriCore/Permissions/PermissionMonitor.swift` per `contracts/core-interfaces.md` and the R5 spike outcome; T011 passes
- [x] T014 [P] Implement `ScreenRecordingAdapter` in `App/Adapters/ScreenRecordingAdapter.swift`: `isGranted()` calls `CGPreflightScreenCaptureAccess()`; `requestAccess()` calls `CGRequestScreenCaptureAccess()`; `openSystemSettings()` opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- [x] T015 Implement `WindowCoordinator` in `App/Windows/WindowCoordinator.swift`: ids `settings`, `onboarding`, `inbox`, `search`; `show(_ id)` creates the `NSWindow` with an `NSHostingController` on first use, reuses it afterwards, places it on the display holding the pointer, calls `NSApp.activate()` and orders it front (one instance per id, per `contracts/ui-contract.md`); titles "Memorri Settings", "Screen Recording Access", "Inbox", "Search"; content views are stubs until later tasks
- [x] T016 Create `App/AppEnvironment.swift` holding the shared services (`PermissionMonitor`, `CaptureFeedbackSettings`, `WindowCoordinator`) and their adapters, created once at launch and passed to the menu and delegate

**Checkpoint**: `swift test --package-path Packages/MemorriCore` passes; the app still builds.

---

## Phase 3: User Story 1 - Trigger a capture from the menu bar (Priority: P1) 🎯 MVP

**Goal**: Icon, full menu, Capture now records a request and gives feedback, Inbox/Search placeholders, Settings opens a window, Quit works.

**Independent Test**: Quickstart Scenario 1.

### Tests for User Story 1 ⚠️ (write first, see them fail)

- [x] T017 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureRequestServiceTests.swift` with a fake `Clock`, fake `FeedbackPlaying` and fake permission: a request less than 300 ms after the previous accepted request returns `nil` and records nothing; a request at 300 ms or later is accepted; `recent` never holds more than 100 items and keeps the newest; with status `granted` and both toggles on, `flashIcon` and `playSound` are each called once; with `flashIcon` off, no flash; with `playSound` off, no sound; with status `notGranted` or `restartRequired` the request is still recorded, no feedback is called, and `onNeedsOnboarding` is called exactly once; each request stores `trigger` and `permissionAtRequest`

### Implementation for User Story 1

- [x] T018 [US1] Implement `CaptureTrigger`, `CaptureRequest` (`id`, `timestamp`, `trigger`, `permissionAtRequest`), `Clock`, `FeedbackPlaying` and the `CaptureRequestService` actor in `Packages/MemorriCore/Sources/MemorriCore/Capture/CaptureRequestService.swift` (debounce 300 ms, ring buffer of the last 100, one `os.Logger` line per accepted request, subsystem `com.aletc1.memorri`, category `capture`, text `capture requested trigger=<menu|shortcut> permission=<granted|notGranted|restartRequired>`); T017 passes
- [x] T019 [P] [US1] Implement `FeedbackAdapter` in `App/Adapters/FeedbackAdapter.swift`: `flashIcon()` sets an observable flag true for about 300 ms then false; `playSound()` plays the system sound "Pop" with `NSSound`
- [x] T020 [P] [US1] Create `App/Windows/PlaceholderView.swift` showing the texts from `contracts/ui-contract.md` ("The Inbox is not built yet. It arrives in a later version." and the Search equivalent) and connect the `inbox` and `search` windows in `WindowCoordinator`
- [x] T021 [US1] Create `App/MenuContent.swift` with the menu from `contracts/ui-contract.md`: Capture now (trigger `menu`), Inbox, Search, separator, "Grant Screen Recording access…" (only while status is not `granted`; "Restart to finish setup…" when `restartRequired`; opens the `onboarding` window), Settings… (Command+,), separator, Quit Memorri (Command+Q)
- [x] T022 [US1] Replace the minimal `App/MemorriApp.swift` with the full app: `MenuBarExtra` using `MenuContent`, label image `MenuBarIconFlash` while the flash flag is on and `MenuBarIcon` otherwise, `AppDelegate` adaptor, `AppEnvironment` creating the `CaptureRequestService` with the adapters and `onNeedsOnboarding` showing the `onboarding` window; create `App/AppDelegate.swift` (empty lifecycle hooks for now)
- [ ] T023 [US1] Run quickstart Scenario 1 and fix any difference from `contracts/ui-contract.md`

**Checkpoint**: User Story 1 works on its own: a menu-only app that records capture requests.

---

## Phase 4: User Story 2 - Trigger a capture with a global hotkey (Priority: P1)

**Goal**: Configurable global shortcut (default Control+Option+Command+M) that produces the same capture request, with validation and persistence.

**Independent Test**: Quickstart Scenarios 2 and 6.

**Depends on**: US1 (the capture request service).

### Tests for User Story 2 ⚠️

- [ ] T024 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ShortcutValidatorTests.swift`: a combo with an empty modifier set returns `.noModifier`; a combo equal to another Memorri action's combo returns `.usedByMemorriAction(name)`; a combo the fake `SystemShortcutChecking` reports as reserved returns `.reservedBySystem`; a valid combo returns `nil`; when several rules apply the first in the order `noModifier`, `usedByMemorriAction`, `reservedBySystem` wins

### Implementation for User Story 2

- [ ] T025 [US2] Implement `KeyCombo` (`keyCode`, `modifiers` as a set of control, option, command, shift), `ShortcutRejection`, `SystemShortcutChecking` and `ShortcutValidator` in `Packages/MemorriCore/Sources/MemorriCore/Shortcuts/ShortcutValidator.swift`; T024 passes
- [ ] T026 [US2] Implement `ShortcutAdapter` in `App/Adapters/ShortcutAdapter.swift`: define `KeyboardShortcuts.Name("capture", default: Control+Option+Command+M)` (the parameter is `default:` in version 2.4.0), register a key-up handler that calls `CaptureRequestService.request(.shortcut)`, implement `SystemShortcutChecking` with `CopySymbolicHotKeys()` from `import Carbon.HIToolbox` (the package's own check is internal; spike R3), and expose `apply(_ combo: KeyCombo?) -> ShortcutRejection?` that runs `ShortcutValidator` and only saves the shortcut when it returns `nil`
- [ ] T027 [US2] Create `App/Windows/ShortcutSection.swift`: a `KeyboardShortcuts.Recorder` used with a binding that routes every change through `ShortcutAdapter.apply`, shows the rejection message from `contracts/ui-contract.md` inline and keeps the previous shortcut, plus a way to clear the shortcut to none (the recorder's clear control, routed through `ShortcutAdapter.apply(nil)`) and a "Reset to default" button that restores Control+Option+Command+M through the same validation and reports if the default is now taken; show it as the only content of the `settings` window for now (T015 stub)
- [ ] T028 [US2] Run quickstart Scenario 2 (log stream, 20 presses spread across at least three different focused apps, debounce, change, clear and reject shortcuts, persistence across three relaunches, reset)
- [ ] T029 [US2] Run quickstart Scenario 6 with your real remote-desktop client in full-screen (20 presses, at least 19 log lines, no duplicates), fill the results table in `specs/001-menubar-shell/quickstart.md`, and if no shortcut passes, stop and write `docs/postmortems/` or a new ADR under `docs/architecture/decisions/` before continuing

**Checkpoint**: User Stories 1 and 2 work; the remote-desktop acceptance result is recorded.

---

## Phase 5: User Story 3 - Grant and monitor Screen Recording permission (Priority: P1)

**Goal**: Clear permission status, onboarding on first launch and on a permission-less capture, status that updates on its own, and a permission that survives rebuilds.

**Independent Test**: Quickstart Scenarios 3 and 4.

### Tests for User Story 3 ⚠️

- [ ] T030 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OnboardingPolicyTests.swift` for `OnboardingPolicy.shouldOpenAtLaunch(completed:status:)`: `completed == false` and status `notGranted` or `restartRequired` → `true`; `completed == false` and status `granted` → `false`; `completed == true` with any status → `false`; and `completedAfterLaunch` is always `true` after the first launch decision

### Implementation for User Story 3

- [ ] T031 [US3] Implement `OnboardingPolicy` (new type, listed in `contracts/core-interfaces.md`) in `Packages/MemorriCore/Sources/MemorriCore/Permissions/OnboardingPolicy.swift` using the `memorri.onboarding.completed` key (default `false`) via `SettingsStore`; T030 passes
- [ ] T032 [US3] Create `App/Windows/OnboardingView.swift`: one short paragraph on why the permission is needed ("to see the screens you choose to capture; nothing leaves this Mac"), a status badge (Granted, Not granted, Restart required), buttons **Open System Settings** (first calls `ScreenRecordingAdapter.requestAccess()` so the app is added to the Screen Recording list and the system prompt appears, then `openSystemSettings()`), **Check again** (`PermissionMonitor.refresh()`) and, when `restartRequired`, **Relaunch Memorri**; connect it to the `onboarding` window in `WindowCoordinator`
- [ ] T033 [US3] Implement relaunch in `App/AppEnvironment.swift`: start a new instance of the app bundle with `NSWorkspace` and terminate the current one after the new one has launched
- [ ] T034 [US3] Add status polling in `App/AppEnvironment.swift`: a timer calls `PermissionMonitor.refresh()` every 2 seconds for as long as the app runs, and also whenever the app becomes active (`NSApplication.didBecomeActiveNotification`) and when the menu opens; the menu (T021) and onboarding view observe `statusUpdates()`, so a revoked permission shows in the menu within 2 seconds
- [ ] T035 [US3] In `App/AppDelegate.swift`, at launch call `OnboardingPolicy.shouldOpenAtLaunch` and show the `onboarding` window when it returns `true`, then persist `completed = true`; confirm that a capture without permission (T022 `onNeedsOnboarding`) opens the same window
- [ ] T036 [US3] Run quickstart Scenarios 3 and 4 (grant flow, no window on later launches, revoke while running, five rebuilds with the requirement unchanged and no prompt, and the negative signing-identity check)

**Checkpoint**: User Stories 1, 2 and 3 work; the permission survives rebuilds.

---

## Phase 6: User Story 4 - Settings skeleton and single instance (Priority: P2)

**Goal**: A Settings window with the agreed sections, one instance of the app, and a second launch that opens Settings in the running app.

**Independent Test**: Quickstart Scenario 5 plus opening Settings and switching sections.

### Tests for User Story 4 ⚠️

- [ ] T037 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SingleInstanceArbiterTests.swift` for `SingleInstanceArbiter.shouldExit(ownPID:otherPIDs:)`: no other process → `false`; another process with a lower PID → `true`; only processes with a higher PID → `false`; ignores its own PID in `otherPIDs`

### Implementation for User Story 4

- [ ] T038 [US4] Implement `SingleInstanceArbiter` (new type, listed in `contracts/core-interfaces.md`) in `Packages/MemorriCore/Sources/MemorriCore/Lifecycle/SingleInstanceArbiter.swift` (rule: the process with the lowest PID keeps running); T037 passes
- [ ] T039 [US4] In `App/AppDelegate.swift`, at launch read the other running copies with `NSRunningApplication.runningApplications(withBundleIdentifier: "com.aletc1.memorri")`, and if `SingleInstanceArbiter.shouldExit` is `true` post the distributed notification `com.aletc1.memorri.openSettings` and terminate; in the running instance observe that notification with `DistributedNotificationCenter` and show the `settings` window
- [ ] T040 [US4] Replace the T027 stub with the full `App/Windows/SettingsView.swift`: `NavigationSplitView` with sidebar order General (selected first), Permissions, Ollama, Storage, Calendar sync; General contains `ShortcutSection` (T027) plus toggles "Flash the menu-bar icon" and "Play a sound" bound to `CaptureFeedbackSettings`; Permissions shows the status row and the same actions as `OnboardingView`; Ollama, Storage and Calendar sync show "Coming in a later version: <what will be here>." and name specs 003, 002 and 009
- [ ] T041 [US4] Run quickstart Scenario 5 and Scenario 1 (Settings step), and confirm the two capture-feedback toggles change what a capture does

**Checkpoint**: All four user stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T042 [P] Add a test `Packages/MemorriCore/Tests/MemorriCoreTests/NoNetworkTests.swift` that scans `Packages/MemorriCore/Sources` and `App` for `URLSession`, `NWConnection`, `import Network` and `CFNetwork`, and scans `project.yml` for any `com.apple.security.network` entitlement, and fails on any match (FR-017)
- [ ] T043 [P] Update `CLAUDE.md`: remove the "(Available once spec 001 has created the project.)" line from Commands and add `scripts/check-signing-identity.sh`; update `README.md` status if the app now runs
- [ ] T044 Add a "Build and run the app" section to `DEVELOPER.md` (generate the project, build, launch, run the tests, where the log is) so a new developer can follow it without other help (FR-016, SC-006)
- [ ] T045 Run the network check from quickstart (`lsof -i -a -p $(pgrep -x Memorri)` shows nothing) and the full quickstart top to bottom; fix anything that differs
- [ ] T046 Run `swift test --package-path Packages/MemorriCore` and `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build`; both must pass with no warnings from our code
- [ ] T047 Validate SC-006: clone the repository into a temporary directory, follow only `DEVELOPER.md` to build and run the app, time it, and confirm it takes under 15 minutes; fix the guide where it fails
- [ ] T048 Set the status of 001 to "Done" in `docs/roadmap.md`, and tick the acceptance checklist in the pull request description (Definition of done, `DEVELOPER.md` section 10)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none. T001 to T006 mostly in order; T004 can run in parallel with T002/T003. The spikes T007 to T009 come after T005 and may run in any order.
- **Foundational (Phase 2)**: after Setup including the spikes (T008 decides whether `restartRequired` exists); blocks every user story.
- **US1 (Phase 3)**: after Foundational. MVP.
- **US2 (Phase 4)**: after US1 (needs `CaptureRequestService`). Tests T024 and the validator T025 can start as soon as Foundational is done.
- **US3 (Phase 5)**: after Foundational; its integration task T035 uses the US1 service, so finish US1 first. T030 to T031 (policy) can run earlier.
- **US4 (Phase 6)**: after Foundational; T040 reuses `ShortcutSection` (US2) and the Permissions actions (US3), so do it after both. T037 to T038 can run earlier.
- **Polish (Phase 7)**: after all stories.

### Within Each User Story

- Tests first and failing, then the core type, then the adapter or view, then wiring, then the manual verification task.

### Parallel Opportunities

- Setup: T004 with T002/T003.
- Foundational: T010 with T011; T014 with T012/T013.
- US1: T019 with T020 after T018.
- Test files for later stories (T024, T030, T037) are independent of each other and can be written in parallel once Foundational is done.
- Polish: T042 with T043.

---

## Parallel Example: Foundational tests

```bash
# Two test files, no shared code:
Task: "Write failing SettingsTests in Packages/MemorriCore/Tests/MemorriCoreTests/SettingsTests.swift"
Task: "Write failing PermissionMonitorTests in Packages/MemorriCore/Tests/MemorriCoreTests/PermissionMonitorTests.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup, then Phase 2 Foundational.
2. Phase 3 User Story 1.
3. **Stop and validate** with quickstart Scenario 1: a menu-bar app that records capture requests.

### Incremental Delivery

1. Setup and Foundational give a signed, buildable app.
2. US1 adds the menu and capture requests.
3. US2 adds the hotkey and answers the biggest risk (the remote-desktop test, T029). If it fails, decide on a workaround before going on.
4. US3 adds permission onboarding and proves the permission survives rebuilds.
5. US4 adds the Settings skeleton and single instance.
6. Polish closes the network check and the docs.

---

## Notes

- Commit after each task or small group, on branch `001-menubar-shell`, with English Conventional Commit messages (`feat(001): …`, `test(001): …`). Do not push or open a PR until asked.
- Tasks named "Verify research Rn" record the result in `research.md` so later specs can rely on it.
- Never add screenshots or captured content to the repository.
