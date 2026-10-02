---

description: "Task list for spec 013: capture only the active window"
---

# Tasks: Capture only the active window, with its own shortcut and a red outline

**Input**: Design documents from `/specs/013-active-window-capture/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (core-interfaces.md, app-and-eval.md), quickstart.md. The branch starts from `main` with specs 009 and 010 merged (the migration is `v13`).

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. No prompt or schema changes are made; the eval protects the full-screen results (US3).

**Organization**: Grouped by user story in priority order: US1 capture the window (P1), US2 the red outline (P1), US3 full-screen unchanged (P1), US4 shortcut and menu (P2), US5 labels (P3). Paths follow plan.md; `Core/` means `Packages/MemorriCore/Sources/MemorriCore/` and `Tests/` means `Packages/MemorriCore/Tests/MemorriCoreTests/`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US5 as in the spec
- Commands assume the repository root as the working directory.
- **Privacy**: tests and eval use synthetic titles and drawn pictures only. Never log a window title or application name. Real captures and the user's real database are opened only where a task says so, with the user's go-ahead and their copy of the app closed (see memory: running copy blocks isolated UI runs).
- Tasks that edit `Tests/Fakes.swift` are not marked parallel.
- US1 is the MVP: after Phase 3 a window capture works from the menu and from debug ingest. US2 to US5 each build on it.

## Phase 1: Setup

**Purpose**: Baseline scores, the two spikes the design depends on, and migration `v13`.

- [X] T001 Record the baseline before any code change: run `swift run --package-path Packages/MemorriCore memorri-eval run` on `main` (needs Ollama; not while the app's queue is busy) and save the report outside the repo (scratchpad); note the per-case scores and model call counts in `specs/013-active-window-capture/research.md` under a new heading "Baseline (before the change)" as counts only
- [X] T002 Spike S1 (research R3): in a throwaway Debug-only snippet under the scratchpad (not committed) call `SCScreenshotManager.captureImage(in:)` for a rectangle on one Retina display and for one spanning two displays of different scales, and a display filter with `sourceRect`; record the returned pixel sizes and scale behaviour in `research.md` under R3 "Result (S1)"; if the spanning case cannot return native pixels, amend R3, `contracts/core-interfaces.md` and the spec edge case to the fallback (the part on the display holding most of the window) before continuing
- [X] T003 [P] Spike S2 (research R8): in a throwaway Debug-only snippet (scratchpad) show a borderless non-activating `NSPanel` with `ignoresMouseEvents`, `sharingType = .none`, a level above the main menu and the all-Spaces and full-screen-auxiliary behaviours from an `LSUIElement` app, over a full-screen application in another Space; record the level and behaviours that worked in `research.md` under R8 "Result (S2)"
- [X] T004 Write failing tests in `Tests/StorageDatabaseTests.swift` for migration `"v13"` per `data-model.md`: `capture_events.scope` is TEXT NOT NULL DEFAULT `'displays'` with a CHECK allowing only `'displays'` and `'window'` (inserting `'other'` fails); `capture_images.desktop_frame_json` is TEXT and nullable; rows inserted before the migration read back with `scope = 'displays'` and a null frame; the `trigger` CHECK still allows only `'menu'` and `'shortcut'`
- [X] T005 Implement migration `"v13"` in `Core/Storage/Migrations.swift`, registered after `"v12"` (`ALTER TABLE … ADD COLUMN`, no table rebuild); the previous task's tests pass

**Checkpoint**: baseline recorded, both spikes answered, migration tests pass.

---

## Phase 2: Foundational

**Purpose**: The scope in storage and the shared types every story uses. Blocks all stories.

- [X] T006 [P] Write failing tests in `Tests/CaptureStoreTests.swift`: `CaptureEventRecord.scope` defaults to `.displays` and round-trips `.window`; `CaptureImageRecord.desktopFrame` (`DesktopRect?`) round-trips through `desktop_frame_json` and is nil for display pictures; `insert(event:images:windows:)` writes both; a window capture holds one image row and one window row with frame `0,0,width,height`, `stack` 0; a new `CaptureStore.scope(imageID:)` returns the event's scope
- [X] T007 Add `CaptureScope` (String-backed, `.displays`, `.window`), `DesktopRect` (Codable; x, y, width, height in points, top-left origin), `scope` on `CaptureEventRecord`, `desktopFrame` on `CaptureImageRecord` and `CaptureStore.scope(imageID:)` in `Core/Storage/CaptureStore.swift` (and `Core/Capture/WindowCapturing.swift` for the shared types); the previous task's tests pass
- [X] T008 [P] Create `Core/Capture/WindowCapturing.swift` per `contracts/core-interfaces.md`: `WindowCandidate`, `WindowCaptureResult`, `WindowCaptureFailure`, the `WindowCapturing` protocol and the `CaptureOutlining` protocol (with a no-op default so existing fakes still compile)
- [X] T009 Add `.windowComplete(app: String?)` and `.noWindow(ActiveWindowReason)` (`none`, `ownWindow`) to `Core/Capture/CaptureOutcome.swift` and update every `switch` over `CaptureOutcome` in `Core/` and `App/` so the project builds; add a fake `WindowCapturing` and `CaptureOutlining` to `Tests/Fakes.swift`

**Checkpoint**: `swift test --package-path Packages/MemorriCore` passes and the app target still builds.

---

## Phase 3: User Story 1 - Capture the window I am looking at (P1)

**Goal**: One picture of only the active window is stored and analysed as one chosen window; its items merge with existing ones.

**Independent test**: Choose "Capture window" from the menu with several windows open on two displays, and ingest the `window-capture-*` eval cases: one stored picture, items only from that window, no duplicates against a full-screen capture.

### Picking the window and storing the capture

- [X] T010 [P] [US1] Write failing tests in `Tests/ActiveWindowPickerTests.swift` for `ActiveWindowPicker.pick`: the front-most layer-0 on-screen window of the frontmost process wins; a layer above 0 (floating panel) is skipped; windows of other processes in front of it are ignored; off-screen windows are skipped; Memorri's own process frontmost gives `.ownWindow`; a frontmost process with no qualifying window gives `.none`; no frontmost process gives `.none`; a tiny window still qualifies
- [X] T011 [US1] Implement `Core/Capture/ActiveWindowPicker.swift` per the contract; the previous task's tests pass
- [X] T012 [P] [US1] Write failing tests in `Tests/CapturePipelineWindowTests.swift` for `CapturePipeline.runWindow(trigger:)` with fakes: stores one event with `scope = window`, `display_count` 1, one image and one window row (frame `0,0,width,height`, `stack` 0, app name, bundle id, title); records `desktop_frame_json`; writes the full and model HEIC files like `run`; enqueues analysis at the default priority when automatic analysis is on; returns `.windowComplete(app:)`; a `noWindow` or `ownWindow` failure stores nothing and returns `.noWindow(reason)`; a permission failure returns `.permissionDenied`; another failure returns `.failed`; below the free-space floor stores nothing; returns nil while another run (either scope) is in progress; a capture error because the window closed or was minimised stores nothing and returns `.failed`; `run(trigger:)` still never calls the window capturer
- [X] T013 [US1] Add `runWindow(trigger:)` and the `WindowCaptureRunning` protocol to `Core/Capture/CapturePipeline.swift` (`run(trigger:)` is not changed), sharing the `isRunning` guard, staging and commit code with `run` through private helpers; the previous task's tests pass and the existing `CapturePipelineTests.swift` still pass unchanged
- [X] T014 [P] [US1] Write failing tests in `Tests/CaptureRequestServiceTests.swift` (extend it) for `requestWindow(_:)`: a window request and a full-screen request within 300 ms count as one (one shared `lastAccepted`); a request while either scope is running is ignored; `.windowComplete` plays the usual flash and sound per settings; `.noWindow` and `.failed` play the warning flash and warning sound; `.permissionDenied` calls `onNeedsOnboarding`; requests are kept in history with their trigger
- [X] T015 [US1] Add `requestWindow(_:)` to `Core/Capture/CaptureRequestService.swift` with a second initialiser argument `windowRunner: (any WindowCaptureRunning)? = nil` (the existing `runner` argument and every existing call site and test stay as they are; with no window runner a window request is ignored), with one shared debounce; the previous task's tests pass and the existing service tests pass unchanged

### Analysing it as one chosen window

- [X] T016 [P] [US1] Write failing tests in `Tests/VisibleScreenTests.swift` (extend): with `chosenWindow: true` and one recorded window covering the picture, `VisibleScreen.split` returns that window as `w0` with every line, `perWindow` true and no desktop lines; a chosen window with 0 to 2 lines, with under 2% visible share, or whose bundle id is a system surface is still kept as `w0` (the drop rules do not apply to it); with `chosenWindow: false` the result is exactly as before (fewer than two windows reads as `"all"`)
- [X] T017 [US1] Add the `chosenWindow` parameter to `VisibleScreen.split` in `Core/Windows/VisibleWindows.swift`: with it, the one recorded window is returned as `w0` before the `windows.count > 1`, system-surface, `minimumShare` and `minimumLines` rules are applied; the previous task's tests pass
- [X] T018 [P] [US1] Write failing tests in `Tests/ReferenceClockTests.swift` (extend) for `windowOnly: true`: a remote window with a clock in its top or bottom strip gives `.windowClock` against that clock; no clock gives `.capture` with `isGuess == false`; a clock more than 24 h from the capture time gives `.captureFarClock` with `isGuess == true`; the screen strip is never searched; `windowOnly: false` behaves exactly as before
- [X] T019 [US1] Add the `windowOnly` rule to `ReferenceClock.find` in `Core/Windows/ReferenceClock.swift`; the previous task's tests pass
- [X] T020 [P] [US1] Write failing tests in `Tests/WindowPipelineTests.swift` (extend) for `PipelineInput.chosenWindow == true`: the windows call runs once and a `relevant: false` answer is overridden to relevant, `kind` kept; one extraction call runs for a non-month window and none for a month grid; a `WindowReadingRecord` is written with the window's app and title; a stored windows answer reused by the job (`reuseWindows`) with `relevant: false` is also overridden; a failed or bad windows answer falls back to the whole-picture path and still extracts; the reference clock uses `windowOnly`; with `chosenWindow == false` the calls and results are identical to before
- [X] T021 [US1] Add `chosenWindow` to `PipelineInput` and the forced-relevance, single-window and `windowOnly` handling to `Core/Extraction/AnalysisPipeline.swift`; the previous task's tests pass
- [X] T022 [P] [US1] Write failing tests in `Tests/ImageAnalysisJobTests.swift` (extend): a job for a picture whose event has `scope = window` builds its input with `chosenWindow == true`; for `displays` it is false; sightings and evidence of the resulting items carry the window's app and title
- [X] T023 [US1] Fill `chosenWindow` from `CaptureStore.scope(imageID:)` in `Core/Analysis/ImageAnalysisJob.swift`; the previous task's tests pass
- [X] T023a [P] [US1] Write failing tests in `Tests/TrialJobRunnerTests.swift` (extend it): a trial run of a picture whose event has `scope = window` builds its `PipelineInput` with `chosenWindow == true`, and for `displays` with false (the trial path builds its own input at `Core/Reprocessing/TrialJobRunner.swift`)
- [X] T023b [US1] Fill `chosenWindow` from `CaptureStore.scope(imageID:)` in `Core/Reprocessing/TrialJobRunner.swift`; the previous task's tests pass
- [X] T024 [P] [US1] Write failing tests in `Tests/ReconcilerWindowsTests.swift` (extend): findings of a window capture reconcile with items made by a full-screen capture (same event gives one item with two sightings); evidence cut-outs of a window capture come from the window picture and follow the 1400 x 800 rule of spec 011

### Running it in the app and in the eval

- [X] T025 [US1] Create `App/Adapters/WindowCaptureAdapter.swift`: `WindowCapturing` over `NSWorkspace.shared.frontmostApplication`, the system's front-to-back window list (as in `ScreenCaptureKitCapturer.windows(on:in:)`), `ActiveWindowPicker.pick`, then the capture per research R3 (display filter excluding Memorri's windows with `sourceRect` for one display, `captureImage(in:)` for a spanning window, frame clipped to the screens, native scale); map `SCStreamError` code -3801 to `.permissionDenied` as `ScreenCaptureKitCapturer.failure(for:)` does; log counts and error domains only, never the app name or title
- [X] T026 [US1] Wire it in `App/AppEnvironment.swift`: build the window capturer, pass the pipeline's `runWindow` to the service, add `requestWindowCapture(_:)` next to `requestCapture(_:)`, and add a "Capture window" button below "Capture now" in `App/MenuContent.swift` calling it with `.menu`; `UnavailableCaptureRunner` also answers `runWindow` with a failure
- [X] T027 [P] [US1] Add a `scope` argument (default `.displays`) to `PictureIngest.store(png:windows:capturedAt:)` in `Core/Capture/PictureIngest.swift` with a test in `Tests/PictureIngestTests.swift`; `App/DebugIngest.swift` `--ingest-case` reads `scope` from `meta.json` and stores a window case as a window capture (one window covering the picture)
- [X] T028 [P] [US1] Add the optional `scope` to `GoldenMeta` in `Core/Evaluation/GoldenCase.swift` (decode default `displays`) and pass `chosenWindow` from it in `Core/Evaluation/PipelineCaseAnalyser.swift`, with tests in `Tests/GoldenCaseTests.swift` and `Tests/PipelineCaseAnalyserTests.swift`
- [X] T029 [US1] Create `Core/Evaluation/SyntheticWindowCaptures.swift` with the five cases of `contracts/app-and-eval.md` (`window-capture-mail`, `window-capture-month-other-month`, `window-capture-remote-clock`, `window-capture-covered`, `window-capture-terminal`), each a drawn window picture with no menu bar and `meta.scope = "window"`, add them to `SyntheticCases.cases` and to `Tests/SyntheticCasesTests.swift`
- [X] T030 [US1] Generate the cases (`swift run --package-path Packages/MemorriCore memorri-eval generate-synthetic`), run the eval (`memorri-eval run`) and record the per-case scores and the seconds per case in `research.md` under R11 "Results" (SC-005: the window cases take no longer than a full-screen case showing the same window alone); the five new cases score 1.00 on dates and kinds; fix the cause (not the case) if not

**Checkpoint**: the menu item stores and analyses a window capture; the new eval cases pass; full-screen tests untouched.

---

## Phase 4: User Story 2 - See exactly what was recorded (P1)

**Goal**: A red outline of the recorded area shows after a successful window capture, never in the picture, never in the way.

**Independent test**: Window captures of windows of different size and position on one and two displays, and over a full-screen window: the outline matches the stored picture's outline, fades by itself, and is absent from the stored picture and from failures.

- [X] T031 [P] [US2] Write failing tests in `Tests/CaptureOutlineGeometryTests.swift` for `CaptureOutlineGeometry.segments(for:displays:)`: a window inside one display gives one segment in that display's local top-left coordinates; a window spanning two displays gives two segments that together cover the frame; a window partly off every screen is clipped (the clipped rectangle is what is outlined); a window touching no display gives none; the flip from the capture coordinate system to AppKit's is not done here (the panel does it)
- [X] T032 [US2] Implement `Core/Capture/CaptureOutline.swift` (`OutlineSegment`, `CaptureOutlineGeometry`); the previous task's tests pass
- [X] T033 [US2] Write failing tests in `Tests/CapturePipelineWindowTests.swift` (extend): `showOutline(for:)` is called exactly once with the window's frame after the event is stored on success; it is never called on any failure, refusal, "no window" or storage error; the stored picture file is written before the outline is shown
- [X] T034 [US2] Add the `CaptureOutlining` dependency and the call to `runWindow` in `Core/Capture/CapturePipeline.swift`; the previous task's tests pass
- [X] T035 [US2] Create `App/Capture/CaptureOutlinePanel.swift` per `contracts/app-and-eval.md` and the S2 result: one borderless non-activating `NSPanel` per display segment, `ignoresMouseEvents`, never key or main, clear background, `sharingType = .none`, the level and collection behaviour found in T003, a 4-point red stroke inside the segment (y flipped for AppKit), shown about 1 s then faded over about 0.25 s, removed afterwards
- [X] T036 [US2] Provide the panel as the `CaptureOutlining` in `App/AppEnvironment.swift` (through `App/Adapters/FeedbackAdapter.swift` if that keeps the main-actor work in one place)
- [X] T037 [US2] Run the app and check by hand (`quickstart.md` section 3, item 2): outline within half a second, matches the window, clicks and keys pass through, absent from the stored picture (open the `*-full.heic` of the capture), shown over a full-screen window in another Space and on both displays for a spanning window, absent on a "no window" attempt; with a small window placed over part of the target the stored picture shows that window and not the covered content (FR-008); record the result in `research.md` under R8 (done through the window list and a pixel check of the stored pictures; looking at the outline over a full-screen app by eye is left to the user)

**Checkpoint**: the outline works in the running app.

---

## Phase 5: User Story 3 - The full-screen capture is unchanged (P1)

**Goal**: Prove nothing about the existing capture moved.

**Independent test**: Existing tests pass unchanged and the eval scores equal the baseline of T001.

- [X] T038 [P] [US3] Add regression tests in `Tests/CapturePipelineTests.swift`: `run(trigger:)` with a window capturer that fails the test if called; the stored event has `scope = displays`, `desktop_frame_json` null, no outline call; the shortcut and menu paths still call `run`
- [X] T039 [US3] Run `swift test --package-path Packages/MemorriCore` and confirm no existing test was edited except to compile (`git diff main -- Packages/MemorriCore/Tests` shows only additions and the `switch` updates of T009)
- [X] T040 [US3] Run `memorri-eval run` again and compare with the T001 baseline using `memorri-eval compare <baseline>.json <after>.json`: no existing case loses more than 0.02 on precision or recall and the model call counts are equal; record the comparison in `research.md` under R11 "Results"
- [X] T041 [US3] Press the existing shortcut and "Capture now" in the running app with two displays: both displays captured, usual flash and sound, no outline (`quickstart.md` section 3, item 3)

**Checkpoint**: SC-004 holds.

---

## Phase 6: User Story 4 - Choose the window-capture shortcut, or use the menu (P2)

**Goal**: A third shortcut with a default, a Settings row, conflict checks against both others, and the menu fallback (already added in T026).

**Independent test**: Change and conflict-test the shortcut in Settings; press the default.

- [X] T042 [P] [US4] Write failing tests in `Tests/ShortcutValidatorTests.swift` (extend): a combination equal to either of two other actions is refused naming that action; the three defaults (Control+Option+Command with M, W and F) are distinct and valid; a system-reserved combination is refused
- [X] T043 [P] [US4] Write failing tests in `Tests/DefaultShortcutResolverTests.swift` for a new pure `DefaultShortcutResolver` in `Core/Shortcuts/`: when the saved capture or search shortcut already equals Control+Option+Command+W the window shortcut starts unassigned and a message says why; otherwise the default is used
- [X] T044 [US4] Implement the resolver in `Core/Shortcuts/DefaultShortcutResolver.swift`; the previous task's tests pass (the validator needs no change if T042 already passes)
- [X] T045 [US4] Refactor `App/Adapters/ShortcutAdapter.swift` to three actions (`capture`, `window`, `search`) with per-action state in place of the two ternaries, `captureWindow` as a `KeyboardShortcuts.Name` with default Control+Option+Command+W, `onKeyUp(for: .captureWindow)` calling `requestWindow(.shortcut)`, labels "Capture now", "Capture window" and "Search", and each check comparing against every other action; apply the resolver at start
- [X] T046 [US4] Add the "Capture window shortcut:" recorder row with "Reset to default" and the rejection text to `App/Windows/ShortcutSection.swift`, and show the shortcut in the menu title in `App/MenuContent.swift`
- [X] T047 [US4] Check by hand (`quickstart.md` section 3, item 4): default works; a new choice survives a restart; setting it to the capture or search shortcut, or to a system-reserved one, is refused with the old one kept; the menu item captures the window of the app that was in front; the shortcut works with a remote-desktop client in front and full screen (spec 001 behaviour) (done: default shortcut and menu item, the three rows in Settings and the menu title; not driven: the recorder refusal, persistence across a restart, a remote-desktop client in front; the rules are unit-tested)

**Checkpoint**: Story 4 acceptance scenarios pass.

---

## Phase 7: User Story 5 - Tell window captures apart (P3)

**Goal**: The menu's last-capture line and the item detail name the window.

**Independent test**: One window capture and one full-screen capture: the menu line and the sighting differ accordingly.

- [X] T048 [P] [US5] Write failing tests in `Tests/LastCaptureLineTests.swift` (extend): a window capture reads `Last window capture: <app>, <age>`; with no application name it reads `Last window capture, <age>`; the "no window to capture" and "Memorri's own windows are not captured" outcomes read as failures with those reasons; the full-screen lines are unchanged
- [X] T049 [US5] Add the window cases to `Core/Capture/LastCaptureLine.swift` and handle them in `App/AppState.swift`; the previous task's tests pass
- [X] T050 [US5] Check that the item detail shows the application and title of a window capture's sighting (spec 011 shows `window_app` and `window_title`); add a test in `Tests/ItemDetailTests.swift` or the nearest existing detail test if none covers a window capture; check by hand in the app (`quickstart.md` section 3, item 5)

**Checkpoint**: Story 5 acceptance scenarios pass.

---

## Phase 8: Polish and cross-cutting

- [X] T051 [P] Check privacy: `grep` the new code for log calls and confirm none includes a title or application name; run the app with `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri"'` during a window capture and confirm none appears; confirm "Delete everything" and retention remove a window capture's rows and files (test in `Tests/CaptureStoreTests.swift` or the existing deletion tests)
- [X] T052 [P] Update `DEVELOPER.md` (how window capture works, the debug ingest for window cases, how to add an eval case), `README.md` if it lists shortcuts, and the roadmap row for 013 in `docs/roadmap.md`
- [X] T053 Set ADR 0028 to Accepted in `docs/architecture/decisions/0028-window-capture-and-outline.md` with a Results section (spike S1 and S2 outcomes, eval scores)
- [X] T054 Full suite and app build: `swift test --package-path Packages/MemorriCore`, `xcodegen generate`, `xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build`; then walk through `quickstart.md` sections 3 and 4 in the running app (use the user's copy only with their go-ahead)
- [X] T055 Write `specs/013-active-window-capture/pr-description.md` (what, why, spec and ADR links, how it was verified, outstanding manual checks)

---

## Dependencies and order

- Phase 1 first (T001 before any code change; T004 and T005 before Phase 2). T002 must finish before T025; T003 before T035.
- Phase 2 blocks everything after it.
- Phase 3 (US1) is the MVP. Within it: T010 to T011 (picker), T012 to T013 (pipeline) and T014 to T015 (service) are independent chains; T016 to T023 (analysis) is a second chain that needs only Phase 2; T025 needs T011 and T013; T026 needs T015 and T025; T029 to T030 need T016 to T021 and T028.
- Phase 4 (US2) needs T013 and the T003 spike. Phase 5 (US3) runs after Phase 3 and Phase 4 so the final eval covers everything. Phase 6 (US4) needs T015 and T026. Phase 7 (US5) needs T009 and T015.
- Phase 8 last.

## Parallel examples

- After Phase 2: T010, T012, T014, T016, T018, T020 and T022 write tests in different files at once; their implementations follow in the order above.
- Phase 4 and Phase 6 touch different files (`CaptureOutline*`, `CaptureOutlinePanel` against `ShortcutAdapter`, `ShortcutSection`) and can run side by side after T026.

## Implementation strategy

1. MVP: Phases 1 to 3. A window capture from the menu is stored, analysed as one window and merged with existing items.
2. Add the outline (Phase 4), then confirm the full-screen capture did not move (Phase 5).
3. Add the shortcut and its settings (Phase 6) and the labels (Phase 7).
4. Close with privacy checks, docs, the ADR and the PR description (Phase 8).
