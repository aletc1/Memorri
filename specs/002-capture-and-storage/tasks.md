---

description: "Task list for spec 002: capture every display and keep the captures"
---

# Tasks: Capture every display and keep the captures

**Input**: Design documents from `/specs/002-capture-and-storage/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. Platform behaviour is proven by the spikes in Phase 1 and by the quickstart scenarios, which can be driven from the terminal on the developer Mac.

**Organization**: Grouped by user story. Paths follow the layout in plan.md (`App/`, `Packages/MemorriCore/`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 capture every display, US2 failed capture and permission, US3 safe storage and restarts, US4 storage figures and cleanup, US5 retention policy, US6 analysis copy size
- Commands assume the repository root as the working directory.

## Phase 1: Setup and spikes

**Purpose**: Add the dependency and prove the platform assumptions on this Mac before building on them (lesson from spec 001, `docs/postmortems/2026-09-29-permission-and-launch-assumptions.md`). Each spike writes its outcome into `research.md`; if an assumption fails, update the plan before Phase 2.

- [x] T001 Add GRDB.swift at exactly 7.11.1 to `Packages/MemorriCore/Package.swift` (`.package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")`, product `GRDB` on the `MemorriCore` target); run `swift build --package-path Packages/MemorriCore` and `swift test --package-path Packages/MemorriCore` and confirm it resolves and the existing tests still pass
- [x] T002 Spike S1 and S3 with a throwaway Swift script in the scratchpad (not committed), run from the terminal (VS Code holds Screen Recording): for each display from `SCShareableContent.current` capture one picture with `SCScreenshotManager.captureImage` (filter per display, `showsCursor = false`, size = display points times `pointPixelScale`), print each picture's pixel size, encode the full picture as HEIC at quality 0.9 and a 2048-long-edge copy with ImageIO, print time and bytes per picture. This Mac has three 3440x1440 displays. Record the outcome under R1 and R3 in `specs/002-capture-and-storage/research.md`; if sizes differ from the 2 MB per display estimate by more than 2x, revise the estimate in `plan.md`
- [x] T003 Spike S4 in a temporary directory: create it with POSIX mode 0700 and `isExcludedFromBackup = true`, then check `ls -ld` and `tmutil isexcluded`; record under R6 in `research.md` (if `tmutil` does not report `[Excluded]`, switch R6 to `tmutil addexclusion` and update the plan)
- [x] T004 Spike S2 in the app: temporarily add a `--spike-capture` launch argument, handled first in `App/MemorriApp.swift`, that captures one display and prints the error type and code from both `SCShareableContent.current` and `captureImage` (or `ok`) and exits. Run it through LaunchServices (`open -n -W --stdout <file> .build/xcode/Build/Products/Debug/Memorri.app --args --spike-capture`; a copy started from a shell is attributed to the terminal, not to Memorri). Run it granted, then after `tccutil reset ScreenCapture com.aletc1.memorri`; also note whether a running app that lost the permission still captures from a cached grant. Record the exact errors under R2 in `research.md`, then remove the spike code

**Checkpoint**: R1, R2, R3 and R6 have recorded outcomes, and the plan still holds.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Storage, settings rules and encoding that every user story needs. Tests first, then code.

- [x] T005 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageSettingsTests.swift`: defaults are analysis copy size 2048 and retention `.days(7)`; `setModelLongEdge` accepts 512 to 4096 and rejects 511 and 4097 keeping the previous value (returns false); `setRetention` accepts `.forever` and `.days(1...3650)` and rejects `.days(0)` and `.days(3651)` keeping the previous value; keys are exactly `memorri.storage.modelLongEdge` and `memorri.storage.retention` (value `forever` or the number of days as text); uses the fake `SettingsStore`
- [x] T006 Implement `RetentionPolicy` and `StorageSettings` in `Packages/MemorriCore/Sources/MemorriCore/Settings/StorageSettings.swift` (and an Int accessor on `SettingsStore` if missing, in `Packages/MemorriCore/Sources/MemorriCore/Settings/SettingsStore.swift`) per `contracts/core-interfaces.md`; the tests pass
- [x] T007 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ImageEncodingTests.swift` with synthetic `CGImage`s (helper in `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift`): `encodeFullResolution` returns HEIC data (readable with `CGImageSource`, type `public.heic`) with the same pixel size as the input; `encodeAnalysisCopy(longEdge: 2048)` of a 3440x1440 image is 2048x857 (longer side equals the value, aspect ratio kept within 1 pixel); a portrait 1440x3440 image gives 857x2048; an image whose longer side is 1000 with `longEdge: 2048` stays 1000x(its height), never enlarged; `longEdge: 1024` gives a longer side of 1024
- [x] T008 Implement `StorageQuality` (`fullResolution = 0.9`, `analysisCopy = 0.9`, named constants), `EncodedPicture`, the `ImageEncoding` protocol and `HEICImageEncoder` in `Packages/MemorriCore/Sources/MemorriCore/Capture/ImageEncoding.swift` (ImageIO `CGImageDestination` with `public.heic` and `kCGImageDestinationLossyCompressionQuality`; downscale with a `CGContext` at high interpolation quality, keeping color space); the tests pass
- [x] T009 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AppPathsTests.swift` using a temporary directory: `prepare()` creates the root, `captures/` and `staging/` with POSIX mode 0700 (`attributes[.posixPermissions] == 0o700`), is idempotent, and marks the root excluded from backups (`URLResourceValues.isExcludedFromBackup == true`); `database` is `<root>/memorri.sqlite`
- [x] T010 Implement `AppPaths` in `Packages/MemorriCore/Sources/MemorriCore/Storage/AppPaths.swift` (default root `~/Library/Application Support/Memorri`); the tests pass
- [x] T011 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureStoreTests.swift` using temporary directories. Schema: table `capture_events` with `id` TEXT primary key, `captured_at` DATETIME not null, `trigger` TEXT not null CHECK (`menu` or `shortcut`), `status` TEXT not null CHECK (`complete`, `partial` or `failed`), `failure_reason` TEXT nullable, `display_count` INTEGER not null; table `capture_images` with `id` TEXT primary key, `event_id` TEXT not null referencing `capture_events.id` ON DELETE CASCADE, `display_id` INTEGER not null, `display_name` TEXT nullable, `pixel_width`, `pixel_height`, `model_width`, `model_height`, `full_bytes`, `model_bytes` INTEGER not null, `scale` REAL not null, `full_path` and `model_path` TEXT not null, `missing` INTEGER not null default 0; indexes on `capture_events(captured_at)` and `capture_images(event_id)`. Tests: inserting a `trigger` of `swipe` or a `status` of `done` fails; deleting an event cascades to its images; opening twice is idempotent; a database with an extra unknown migration opens as `refusedNewerVersion` and is not modified; a file containing garbage opens as `openedAfterSettingAside` with the garbage renamed `memorri.sqlite.damaged-<yyyyMMdd-HHmmss>` kept on disk and a new usable database; store: insert, `count`, `events(olderThan:)` with the boundary (an event exactly at the cutoff is not older), `deleteEvents`, `markMissing`, `allImages`
- [x] T012 Implement `Migrations` (migration `"v1"` as specified above), `StorageDatabase.open(paths:)` (GRDB `DatabasePool`, foreign keys on, `hasBeenSuperseded`, damaged-file handling), `CaptureEventRecord`, `CaptureImageRecord` and `CaptureStore` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift`, `Packages/MemorriCore/Sources/MemorriCore/Storage/StorageDatabase.swift` and `Packages/MemorriCore/Sources/MemorriCore/Storage/CaptureStore.swift`; the tests pass
- [x] T013 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureFileStoreTests.swift` using temporary directories: `makeStagingDirectory` creates a unique directory under `staging/`; `commit` renames it to `captures/<yyyy-MM>/<eventID>/` (month from `capturedAt` in UTC; staging directory gone, final directory exists with its files); `discard` removes a staging directory; `removeCaptureDirectory` removes the final directory; `reconcile(with:)` empties `staging/`, removes a `captures/…/<id>` directory that has no record, marks `missing` for a record whose file is gone, and leaves complete captures untouched
- [x] T014 Implement `CaptureFileStore` in `Packages/MemorriCore/Sources/MemorriCore/Storage/CaptureFileStore.swift`; the tests pass
- [x] T015 Define the capture types and test fakes: `CapturedDisplay`, `CaptureFailure`, `DisplayCaptureResult` and the `DisplayCapturing` protocol in `Packages/MemorriCore/Sources/MemorriCore/Capture/DisplayCapturing.swift`; `CaptureOutcome` and `LastCaptureResult` in `Packages/MemorriCore/Sources/MemorriCore/Capture/CaptureOutcome.swift`; the `DiskSpaceChecking` protocol; the `CaptureStoring` protocol (with `insert(event:images:)`, implemented by `CaptureStore`) in `Packages/MemorriCore/Sources/MemorriCore/Storage/CaptureStore.swift`; and in `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift` a `FakeDisplayCapturer` (scripted results, optional suspension), `FakeDiskSpace`, `FailingEncoder`, `FailingStore` and a synthetic image helper
- [x] T016 Add the warning feedback, test first (a failing `CaptureRequestServiceTests` case that `FakeFeedback` records `flashWarning` and `playWarningSound` when called), then: `flashWarning()` and `playWarningSound()` on `FeedbackPlaying` in `Packages/MemorriCore/Sources/MemorriCore/Capture/CaptureRequestService.swift`, counting versions in `FakeFeedback`, the implementation in `App/Adapters/FeedbackAdapter.swift` (icon shown in a warning look for about 600 ms using the SF Symbol `exclamationmark.triangle.fill` (no new asset); sound "Basso"), and an `isWarning` flag in `App/AppState.swift`

**Checkpoint**: `swift test --package-path Packages/MemorriCore` passes and the app builds.

---

## Phase 3: User Story 1 - Capture every display with one action (Priority: P1) 🎯 MVP

**Goal**: one request stores one full-resolution and one analysis picture per distinct display, atomically, and the menu shows the result.

- [x] T017 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CapturePipelineTests.swift` with fakes and temporary directories: three displays give three full and three analysis pictures, one `complete` event with `display_count` 3 and three image rows, and an empty `staging/`; the analysis copy's longer side equals `modelLongEdge` or the original when smaller; a second `run` while one is in progress returns nil and does nothing (FR-011); less than 1_073_741_824 bytes free gives `.failed("Not enough free disk space")`, no capture call and a `failed` event with no images; `failedDisplayCount` of 1 among 3 gives `.partial(captured: 2, of: 3)`, keeps the two pictures and records `partial` with reason `1 of 3 displays could not be captured`; `CaptureFailure.noDisplays` gives `.failed("no display available")`; a failing encoder gives `.failed("could not save the pictures")`, leaves no directory in `staging/` or `captures/` and no image rows, and records one `failed` event with reason `could not save the pictures` (FR-003); a failing store gives the same outcome and cleanup but records nothing (the store is what failed); with the data folder removed between two runs, the second run recreates it and succeeds (edge case)
- [x] T018 [US1] Implement `CapturePipeline` in `Packages/MemorriCore/Sources/MemorriCore/Capture/CapturePipeline.swift` (actor with `isRunning`; first re-create the data folders with `AppPaths.prepare()` through the file store; order: free-space check, capture, parallel encode per display with a `TaskGroup`, write into staging, `commit`, insert records in one transaction, cleanup on any failure; `permissionDenied` is handled in User Story 2); log `capture finished status=… displays=… images=… ms=…` and `capture refused reason=…` in category `capture`; the tests pass
- [x] T019 [US1] Rewrite the tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureRequestServiceTests.swift` for the new flow: after the 300 ms debounce the service calls the pipeline; `complete` plays the success flash and sound honouring the two switches; `partial` and `failed` play the warning flash and sound honouring the same two switches; a nil outcome (already running) plays nothing; the request is recorded with trigger and time; the old rule that refused feedback from the tracked permission status is removed (the real capture decides)
- [x] T020 [US1] Update `CaptureRequestService` in `Packages/MemorriCore/Sources/MemorriCore/Capture/CaptureRequestService.swift`: new `init` taking the pipeline, `request` returns the `CaptureOutcome?`, feedback and the `onNeedsOnboarding` callback follow the outcome; the tests pass
- [x] T021 [P] [US1] Implement `ScreenCaptureKitCapturer` (`DisplayCapturing`) in `App/Adapters/ScreenCaptureKitCapturer.swift` using the spike outcomes: displays from `SCShareableContent.current`, mirror sets reduced to one display (`CGDisplayIsInMirrorSet`, `CGDisplayMirrorsDisplay`), `SCContentFilter(display:excludingWindows: [])`, `showsCursor = false`, native pixel size, per-display capture in parallel, a failing display counted in `failedDisplayCount` without stopping the others, and errors mapped to `CaptureFailure` (`permissionDenied` mapping finished in User Story 2)
- [x] T022 [P] [US1] Implement `DiskSpaceAdapter` (`DiskSpaceChecking`) in `App/Adapters/DiskSpaceAdapter.swift` reading `volumeAvailableCapacityKey` for the volume holding the data folder, and in Debug builds only (`#if DEBUG`) honour the launch argument `--simulate-free-bytes <n>`
- [x] T023 [US1] Wire the flow in `App/AppEnvironment.swift`: create `AppPaths` (default root) and call `prepare()`, open the database with `StorageDatabase.open` (minimal handling now; full handling in User Story 3), create `CaptureFileStore`, `CaptureStore`, `StorageSettings` over the existing `UserDefaultsSettingsStore`, the encoder, the adapters and the `CapturePipeline`, and pass the pipeline to `CaptureRequestService`; keep the hotkey and menu paths calling `requestCapture`
- [x] T024 [US1] Show the result in the menu: add `lastCaptureResult` and a 30-second time tick to `App/AppState.swift` (set from the outcome), and a disabled first line in `App/MenuContent.swift` with the exact texts from `contracts/ui-contract.md` (`No capture yet`, `Last capture: complete, <age>`, `Last capture: 2 of 3 displays captured, <age>`, `Last capture failed: <reason>, <age>`; relative age with `RelativeDateTimeFormatter`); the warning look of the icon follows `isWarning`
- [ ] T025 [US1] Run quickstart Scenario 1 on this Mac (three displays, automation for the key press and `sqlite3`, `find`, `sips` for the checks), record in the quickstart results table the observed time to feedback (SC-001), the 20-capture counts (SC-002) and pointer check (SC-012), and menu responsiveness during a capture (SC-009), and fix any difference from `contracts/ui-contract.md`

**Checkpoint**: User Story 1 works on its own: one press stores pictures for every display, atomically, with the result in the menu.

---

## Phase 4: User Story 2 - A failed capture is reported and fixes the permission state (Priority: P1)

**Goal**: the real capture is the source of truth for the permission; a refused capture opens onboarding and leaves nothing behind.

- [x] T026 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/PermissionMonitorTests.swift` for `captureSucceeded()` (from `notGranted`, `restartRequired` and `granted` the status becomes `granted`, change emitted once) and `captureDeniedByPermission()` (from `granted` and `restartRequired` the status becomes `notGranted`, from `notGranted` it stays)
- [x] T027 [US2] Implement `captureSucceeded()` and `captureDeniedByPermission()` in `Packages/MemorriCore/Sources/MemorriCore/Permissions/PermissionMonitor.swift`; update the transition table in `specs/001-menubar-shell/data-model.md` and the 002 data model; the tests pass
- [x] T028 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CapturePipelineTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureRequestServiceTests.swift`: a `permissionDenied` failure stores no pictures, records a `failed` event with reason `permission denied`, leaves `staging/` empty and returns `.permissionDenied`; the service then calls `captureDeniedByPermission()`, calls `onNeedsOnboarding` once and plays no feedback; a `complete` or `partial` outcome calls `captureSucceeded()` even when the status was `notGranted` or `restartRequired`; a `failed` outcome for another reason leaves the permission status unchanged (FR-009)
- [x] T029 [US2] Implement the `permissionDenied` path in `Packages/MemorriCore/Sources/MemorriCore/Capture/CapturePipeline.swift` and the permission calls in `Packages/MemorriCore/Sources/MemorriCore/Capture/CaptureRequestService.swift`; finish the error mapping in `App/Adapters/ScreenCaptureKitCapturer.swift` using the S2 outcomes; the tests pass
- [ ] T030 [US2] Run quickstart Scenarios 2 and 3 on this Mac (`tccutil reset` while the app runs, then a capture; `--simulate-free-bytes` for the disk refusal, 5 trials) and fix any difference

**Checkpoint**: User Stories 1 and 2 work: a revoked permission is found by the capture itself and onboarding opens.

---

## Phase 5: User Story 3 - Captures are kept safely and survive restarts (Priority: P1)

**Goal**: start-up prepares storage, reconciles leftovers, survives restarts and handles damaged or newer databases.

- [x] T031 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageBootstrapTests.swift` with temporary directories: the first start creates the folder and an empty database; after 3 captures a new start (simulated relaunch) still finds all 3; at start a leftover `staging/` directory and a `captures/…` directory without a record are removed and a record whose file is missing is marked `missing` (FR-014); a damaged database gives a result carrying the set-aside file name and a working new database; a newer database gives a result that disables capture and leaves the file unchanged
- [x] T032 [US3] Implement `StorageBootstrap.start(paths:)` (prepare paths, open the database, reconcile, return a `StorageContext` with the stores and either a notice or a `capturingDisabledReason`) in `Packages/MemorriCore/Sources/MemorriCore/Storage/StorageBootstrap.swift`; add it to `specs/002-capture-and-storage/contracts/core-interfaces.md`; the tests pass
- [x] T033 [US3] Use `StorageBootstrap` in `App/AppEnvironment.swift` and show the one-time messages from `contracts/ui-contract.md` (`NSAlert` for a damaged database set aside, and for a database from a newer version); when capturing is disabled, Capture now reports `Last capture failed: database from a newer version` and stores nothing
- [ ] T034 [US3] Run quickstart Scenario 4 (three relaunches, `ls -ld`, `tmutil isexcluded`, planted leftovers, a deleted picture, a garbage database) and fix any difference

**Checkpoint**: User Stories 1 to 3 work: captures are kept safely, privately and across restarts.

---

## Phase 6: User Story 4 - See how much space captures use and clean up (Priority: P2)

**Goal**: the Storage section shows real figures and deletes captures on request, never touching anything derived from them.

- [x] T035 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageStatsTests.swift`: `summary()` reports the capture count from the database, `pictureBytes` equal to the sum of the file sizes under `captures/` read from disk, and `databaseBytes` covering `memorri.sqlite`, `-wal` and `-shm`; a file changed outside the app is reflected (SC-006)
- [x] T036 [US4] Implement `StorageSummary` and `StorageStats` in `Packages/MemorriCore/Sources/MemorriCore/Storage/StorageStats.swift`; the tests pass
- [x] T037 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CleanupServiceTests.swift`: `preview(olderThanDays: 30)` returns the count and bytes of captures older than 30 days; `delete(olderThanDays: 30)` removes exactly those events and their directories, leaves newer ones and returns the count; a capture exactly 30 days old is not removed; `delete(olderThanDays: nil)` removes all captures; files and tables outside `captures/` and the two capture tables (a sentinel file next to the database and a sentinel table standing in for later items) are untouched (FR-023); a directory under `staging/` (a capture in progress) is untouched; a `delete` running at the same time as a `CapturePipeline.run` (both on temporary directories) leaves the new capture complete and the database consistent; nothing matching gives 0
- [x] T038 [US4] Implement `CleanupService` in `Packages/MemorriCore/Sources/MemorriCore/Storage/CleanupService.swift` (one delete path: rows in one transaction, then directories; log `cleanup removed=<n>`); the tests pass
- [x] T039 [US4] Create `App/Windows/StorageSettingsView.swift` with the summary (`<N> captures`, `Pictures: <size>`, `Database: <size>`, refreshed each time the section opens, computed off the main actor), the field `Delete captures older than <n> days` with **Delete…**, and **Delete all captures…**, each opening the confirmation from `contracts/ui-contract.md` (cancel is the default; `No captures match.` when nothing qualifies); replace the Storage placeholder in `App/Windows/SettingsView.swift`; construct `StorageStats` and `CleanupService` in `App/AppEnvironment.swift`
- [ ] T040 [US4] Run quickstart Scenario 5 (figures against `du`, backdate with `sqlite3`, delete older than 30 days, cancel, delete all) and fix any difference

**Checkpoint**: User Stories 1 to 4 work: the user sees and controls what stays on the Mac.

---

## Phase 7: User Story 5 - Keep captures only as long as the user wants (Priority: P2)

**Goal**: the retention policy (default 7 days) is applied at start and about daily, and changing it is confirmed.

- [ ] T041 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/RetentionServiceTests.swift` with a fake `TimeSource`: `apply(now:)` with `.days(7)` removes captures older than 7 days and keeps the rest; `.forever` removes nothing; `runIfDue(now:)` does nothing when `memorri.retention.lastRun` is less than 24 hours old and runs (and stores the time) when it is 24 hours old or missing; `removalPreview(for:)` of a shorter policy returns the count and bytes that would go (FR-018); it never touches anything outside captures
- [ ] T042 [US5] Implement `RetentionService` in `Packages/MemorriCore/Sources/MemorriCore/Storage/RetentionService.swift` on top of `CleanupService` (log `retention removed=<n>`); the tests pass
- [ ] T043 [US5] Run retention at start and then check hourly in `App/AppEnvironment.swift` (`apply` at start, `runIfDue` every hour), and add the `Keep captures` picker (`Forever` or `For <n> days`, default 7) to `App/Windows/StorageSettingsView.swift` with the note "Captures are the raw screenshots. Appointments, tasks and reminders found in them are always kept." and the shortening confirmation from `contracts/ui-contract.md`
- [ ] T044 [US5] Run quickstart Scenario 6 (default shows 7 days, backdate and relaunch, `Forever`, shortening with confirmation) and fix any difference

**Checkpoint**: User Stories 1 to 5 work: old captures expire on their own, items are never touched.

---

## Phase 8: User Story 6 - Choose the size of the analysis copy (Priority: P3)

**Goal**: the analysis copy size is editable, validated, and applies to later captures only.

- [ ] T045 [P] [US6] Write a failing test in `Packages/MemorriCore/Tests/MemorriCoreTests/CapturePipelineTests.swift`: with `modelLongEdge` 2048 a capture gives 2048-long analysis copies; after `setModelLongEdge(1024)` the next capture gives 1024 and the stored earlier capture's files and rows are unchanged
- [ ] T046 [US6] Add the `Longer side of the analysis copy (pixels)` field (range 512 to 4096, default 2048, note "Applies to new captures.") to `App/Windows/StorageSettingsView.swift`, showing `Enter a value between 512 and 4096.` and keeping the previous value when `setModelLongEdge` returns false; make the pipeline read the setting at the start of each run
- [ ] T047 [US6] Run quickstart Scenario 7 (1024, invalid 100, back to 2048, a display smaller than the size) and fix any difference

**Checkpoint**: all six user stories work independently.

---

## Phase 9: Polish and cross-cutting concerns

- [ ] T048 [P] Update the design documents to match what was built: `specs/002-capture-and-storage/contracts/core-interfaces.md` (changed signatures, `StorageBootstrap`, `CaptureStoring`), `data-model.md` and `research.md` (spike outcomes already recorded; note any deviation), and set ADRs 0009 and 0010 in `docs/architecture/decisions/` from `Proposed` to `Accepted` (or supersede with a note if a spike changed a decision)
- [ ] T049 [P] Update `DEVELOPER.md` (where the data lives, `~/Library/Application Support/Memorri/`, how to inspect it with `sqlite3`, how to reset it, the `--simulate-free-bytes` Debug argument) and the status line in `README.md` (the app now captures and stores)
- [ ] T050 Run `swift test --package-path Packages/MemorriCore` (the no-network source scan from spec 001 now covers the new code) and a clean `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode clean build`; both must pass with no warnings from our code; run `lsof -i -a -p $(pgrep -x Memorri)` and confirm no connections
- [ ] T051 Run quickstart Scenario 8 with the real remote-desktop client full-screen (10 presses, a second apart), fill the results table in `specs/002-capture-and-storage/quickstart.md`, and if a capture of that display is black or incomplete write a postmortem in `docs/postmortems/` before finishing
- [ ] T052 Validate a fresh clone: clone the repository into a temporary directory, follow only `DEVELOPER.md` to build and test, and confirm GRDB resolves and everything passes; time it
- [ ] T053 Set the status of 002 to `Done` in `docs/roadmap.md` and prepare the pull request description with the Definition of done checklist from `DEVELOPER.md` (say which success criteria were observed by hand and not measured)

---
## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup and spikes)**: none. T001 first; the spikes T002 to T004 can run in any order after it. Their outcomes may change the plan.
- **Phase 2 (Foundational)**: after Phase 1; blocks every user story. The test and implementation pairs can proceed pair by pair in parallel (settings, encoding, paths, database, file store).
- **US1 (Phase 3)**: after Foundational. MVP.
- **US2 (Phase 4)**: after US1 (extends the pipeline and the service).
- **US3 (Phase 5)**: after US1 (reuses the wiring in `AppEnvironment`); its tests can start after Foundational.
- **US4 (Phase 6)**: after US3 (uses the started storage); `StorageSettingsView.swift` is also edited by US5 and US6, so those follow in order.
- **US5 (Phase 7)**: after US4 (builds on `CleanupService` and the Storage view).
- **US6 (Phase 8)**: after US4 (the Storage view); its pipeline test can start after US1.
- **Polish (Phase 9)**: after all stories.

### Within Each User Story

- Tests first and failing, then the core type, then the adapter or view, then wiring, then the quickstart scenario.

### Parallel Opportunities

- Foundational test files (settings, encoding, paths, database, file store) are independent and can be written in parallel.
- US1: the ScreenCaptureKit adapter and the disk-space adapter (different files).
- US2: the permission tests with nothing else; US3 and US4 test files once Foundational is done.
- Polish: the two documentation tasks.

---

## Parallel Example: Foundational tests

```bash
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/StorageSettingsTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/ImageEncodingTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/AppPathsTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/CaptureFileStoreTests.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 (spikes) and Phase 2 (foundation).
2. Phase 3: one press stores one picture set per display, atomically, and the menu shows the result.
3. **Stop and validate** with quickstart Scenario 1.

### Incremental Delivery

1. The spikes answer the platform questions first (permission errors, sizes, backup exclusion).
2. US1 gives real captures; US2 makes the permission honest; US3 makes storage safe across restarts.
3. US4 and US5 give control over disk use (the 7-day default); US6 makes the analysis size tunable.
4. Polish closes the docs, the remote-desktop check and the fresh-clone check.

---

## Notes

- Commit after each task or small group, on branch `002-capture-and-storage`, with English Conventional Commit messages (`feat(002): …`, `test(002): …`). Do not push or open a PR until asked.
- Tasks named "Spike" record their result in `research.md` so the plan stays honest.
- Looking at a stored picture means viewing the user's own screen content: do it only on a prepared test screen and with the user's consent.
- The UI can be driven from the terminal with the automation available on this Mac (Accessibility and Screen Recording granted to VS Code), as done in spec 001.
