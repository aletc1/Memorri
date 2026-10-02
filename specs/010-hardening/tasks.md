# Tasks: hardening (spec 010)

Paths are relative to `Packages/MemorriCore/Sources/MemorriCore/` (Sources), `Packages/MemorriCore/Tests/MemorriCoreTests/` (Tests) or the repository root (App/, scripts/, docs/). Tests come before the code they cover (constitution VI). Stories follow the spec: US1 cancellation (P1), US2 backup and restore (P1), US3 notifications (P2), US4 launch at login (P3), US5 diagnostics (P3), US6 app icon (P3).

## Phase 1: Foundation
- [x] T001 Migration v12 as in data-model.md: tables `calendar_coverage` (PK `image_id`, `window_key`; `kind IN ('calendar_week','calendar_day')`; `spans_json` NOT NULL; cascade on capture images) and `cancel_absences` (PK `item_id`, `image_id`; cascade on items and images), the index `cancel_absences_item` (no context column: the context comes from `image_context`), and `items.cancel_cleared_at DATETIME`; migration test that a v11 database keeps its items and gains the tables, and that deleting an item or a capture removes its rows (Sources/Storage/Migrations.swift, Tests/StorageDatabaseTests.swift)
- [x] T002 [P] `ReconcileSummary.createdItemIDs: [String]`, filled by `Reconciler.apply` when an item is created; test (Sources/Reconciliation/Reconciler.swift, Sources/Reconciliation/ReconcilerApply.swift, Tests/ReconcilerTests.swift)
- [x] T003 [P] `ReviewReason.possiblyCancelled = "possibly-cancelled"`, its words `Possibly cancelled` in `ItemListModel.reviewText`, and the Inbox counting it; test of the words (Sources/Reconciliation/Item.swift, Sources/Reconciliation/ItemListModel.swift, Tests/ItemListModelTests.swift)

## Phase 2: US1 Cancellation detection (FR-001 to FR-008)
**Goal**: a meeting missing from two later captures of the same calendar dates is flagged in the Inbox, never removed.
**Independent test**: capture a week view with three meetings, then twice a week view of the same dates and context with two; after the first nothing changes, after the second the missing one is `Possibly cancelled`; `Still happening` clears it, `Cancelled` dismisses it.
- [x] T004 [US1] Tests first for `CoverageReader`: a week view whose headers, visible window and hour labels are known gives one span per visible day between the first and last visible hour label, in absolute instants across zones; no coverage for a month view, for a capture with no context, for a header with `monthAssumed` or `monthConflict`, for fewer than three hour labels, for a day column outside the visible boxes, or for non-calendar kinds (Tests/CoverageReaderTests.swift)
- [x] T005 [US1] `CalendarCoverage` and `CoverageReader` (spans from `DateResolver.headers`, `WindowReadingRecord.visible` and the hour labels of the left margin; nil means silence); `AnalysisResult.coverage` filled by `AnalysisPipeline` in both the window path and the single-picture path (Sources/Reconciliation/CalendarCoverage.swift, Sources/Extraction/CoverageReader.swift, Sources/Extraction/AnalysisPipeline.swift)
- [x] T006 [US1] Tests first for `ReviewRules` with the new input: flagged only when the item is active and has absences from two different capture events captured after `max(lastSighting, clearedAt)`; one absence, two from the same event, or a sighting after the absences gives no flag; approved items are flagged too and keep their other reasons; dismissed items never are (Tests/ReviewRulesTests.swift)
- [x] T007 [US1] `ReviewRules.reasons(... cancelAbsences:lastSighting:clearedAt:)` and `ItemRecompute.applyReview` reading `cancel_absences` and `cancel_cleared_at` (Sources/Reconciliation/ReviewRules.swift, Sources/Reconciliation/ItemRecompute.swift)
- [x] T008 [US1] Tests first for `CancellationDetector`: records coverage on a first analysis; writes an absence only for active appointments of the same context with a moment inside a span, not all-day, with an earlier sighting in an image that has coverage, and no sighting in this image; none for other contexts or when the capture has no context (also when its context was changed after analysis: the current `image_context` rules), none for other days, non-calendar captures, items seen only on non-calendar screens; two covering captures flag the item, one does not; a later sighting clears the absences and the flag; re-read, `force` and trial paths add no absence and only delete contradicted ones; deleting a capture (as retention does) removes its absences and the flag goes with them (Tests/CancellationDetectorTests.swift)
- [x] T009 [US1] `CancellationDetector.record(imageID:)` and `clearContradicted(imageID:)`; called by `ImageAnalysisJobRunner` after the reconcile of an `analyse` job (never for `force` or `reread`), then `recompute` of the touched items (Sources/Reconciliation/CancellationDetector.swift, Sources/Analysis/ImageAnalysisJob.swift)
- [x] T010 [US1] Tests then `ItemOperations.confirmStillHappening`: approves, sets `cancel_cleared_at`, deletes the absences and stores them in the operation so Undo restores the flag; absences count again only after a later sighting; `Cancelled` through `dismiss` leaves the sync entry removal to sync and is undoable (Tests/CancellationDecisionTests.swift, Sources/Reconciliation/ItemOperations.swift, Sources/Reconciliation/ItemUndo.swift)
- [x] T011 [US1] Item detail block `Possibly cancelled` with the last capture that showed the item, the dates of the captures that did not show it and the buttons `Cancelled` and `Still happening`, per ui-contract 1; `ItemsViewModel` actions (App/Windows/ItemDetailView.swift, App/Windows/ItemsViewModel.swift)
- [x] T012 [US1] Synthetic sequences of captures with known cancellations, fed to the detector as coverage spans plus findings (no OCR: the reader is covered by T004), scored in `Tests/CancellationSequenceTests.swift`: at least 90% of cancellations flagged, at most 1 in 20 flags wrong, 0 flags from non-calendar, non-covering or context-less captures (SC-001, SC-003); a mutation check that empty coverage gives no flags (Tests/CancellationSequenceTests.swift); reporting through `memorri-eval` is not added: the sequences need spans, which the CLI has no OCR to produce

## Phase 3: US2 Export, backup and restore (FR-016 to FR-022)
**Goal**: items leave as a readable file, the library as a backup that restores safely.
**Independent test**: export, back up, change the library, restore and restart: the library matches the backup and a safety copy exists; a foreign or newer file is refused with nothing changed.
- [x] T013 [US2] Tests first for `ItemExporter`: every item including dismissed and merged, fields, locks, review state, aliases, sightings with their text, sync state; no pictures; atomic write; round-trips through `JSONDecoder` (Tests/ItemExporterTests.swift)
- [x] T014 [US2] `ItemExporter` (Sources/Backup/ItemExporter.swift)
- [x] T015 [US2] Tests first for `LibraryBackup`: a consistent snapshot while a writer runs, a manifest with sizes and SHA-256 of every file, `Include capture pictures` off leaves out `captures/`, both sizes known beforehand, cancel leaves no partial package, a full disk is refused before starting (Tests/LibraryBackupTests.swift)
- [x] T016 [US2] `LibraryBackup` and `BackupManifest` (GRDB online backup, `copyItem`, progress, cancellation) (Sources/Backup/LibraryBackup.swift)
- [x] T017 [US2] Tests first for `LibraryRestore` and the launch swap: validation refuses a non-backup, a damaged file (checksum), a newer schema; staging writes `restore-pending/`; `StorageBootstrap.finishStagedRestore` moves the current database, `evidence/` and `captures/` into `safety-copies/<timestamp>/`, moves the staged files in, writes `restore-result.json`, and moves everything back on any failure; a backup without pictures leaves restored captures with no picture; the library is byte-identical on a failed restore (Tests/LibraryRestoreTests.swift)
- [x] T018 [US2] `LibraryRestore` (with `cancelStaged`, which deletes `restore-pending/`; tested), `StorageBootstrap.finishStagedRestore` called before the database opens, `SafetyCopies` (list, delete); `StorageStats` counts safety copies and `restore-pending/` in the storage totals (Tests/StorageStatsTests.swift) (Sources/Backup/LibraryRestore.swift, Sources/Backup/SafetyCopies.swift, Sources/Storage/StorageBootstrap.swift)
- [x] T019 [US2] After a restore the first sync waits for a preview: reset `sync.firstSyncConfirmed` in the finished restore; test (Sources/Backup/LibraryRestore.swift, Tests/LibraryRestoreTests.swift)
- [x] T020 [US2] Settings > Storage: `Export items…`, `Back up library…` (sheet with both sizes, picture switch, progress, cancel, the not-encrypted note), `Restore from backup…` (validation result, what is replaced, `This backup has no capture pictures` when so, `Restore and restart`, `Cancel restore` while staged), the safety copies list with `Delete` (App/Windows/StorageSettingsView.swift, App/Backup/BackupPanels.swift)

## Phase 4: US3 Notifications (FR-009 to FR-013)
**Goal**: one quiet notice per burst of new items.
**Independent test**: three captures in a minute give one notice with the totals; none with the Items window in front or the switch off.
- [ ] T021 [US3] Tests first for `NewItemsNotifier` and `NotificationWords`: a burst fires once after the quiet period and never later than the ceiling; counts use items still active at firing time and how many need review or became possibly cancelled; nothing when empty, when disabled, or for ids not from first analyses; wording `3 new items, 1 needs review` with singular forms (Tests/NewItemsNotifierTests.swift)
- [ ] T022 [US3] `NewItemsNotifier`, `NoticeShowing`, `NotificationWords`; `ImageAnalysisJobRunner` reports `createdItemIDs` of `analyse` jobs only (Sources/Notifications/NewItemsNotifier.swift, Sources/Notifications/NotificationWords.swift, Sources/Analysis/ImageAnalysisJob.swift)
- [ ] T023 [US3] App adapter over `UNUserNotificationCenter`: asks permission at the first notice, skips when the Items window is frontmost, click opens the Inbox or all items; setting `notifications.enabled` (default on) in General with the permission state and `Open System Settings` (App/Notifications/NotificationCentreAdapter.swift, App/AppEnvironment.swift, App/Windows/SettingsView.swift)

## Phase 5: US4 Launch at login (FR-014, FR-015)
**Goal**: Memorri starts with the Mac when the user says so.
**Independent test**: switch on and see it in Login Items; remove it there and the switch shows off.
- [ ] T024 [P] [US4] Tests first with a fake `LoginItemControlling`: status mapping (enabled, requires approval, not registered), register and unregister, off by default (Tests/LoginItemTests.swift)
- [ ] T025 [US4] `LoginItem` and the `SMAppService.mainApp` adapter; General section row with the approval note and the System Settings button (Sources/Lifecycle/LoginItem.swift, App/Login/ServiceManagementLoginItem.swift, App/Windows/SettingsView.swift)

## Phase 6: US5 Diagnostics (FR-023 to FR-026)
**Goal**: figures and recent log lines the user can share without exposing the library.
**Independent test**: a library with planted titles, places, people, notes and OCR words gives a report that contains none of them.
- [ ] T026 [P] [US5] Tests first for `LogSanitiser` and `DiagnosticsReport`: category allow list; lines containing a sensitive string of at least 4 characters (lowercase substring) or longer than 12 words are dropped, also failure reasons; the report holds versions, permissions, queue counts and failure reasons, sync runs and problems, storage use; planted strings (titles, places, people, notes, window titles, model output, OCR words) never appear in text or JSON (Tests/DiagnosticsReportTests.swift)
- [ ] T027 [US5] `DiagnosticsReport`, `DiagnosticsInputs`, `LogSanitiser` (Sources/Diagnostics/DiagnosticsReport.swift, Sources/Diagnostics/LogSanitiser.swift)
- [ ] T028 [US5] App: gather the figures, read this process's log with `OSLogStore` (subsystem `com.aletc1.memorri`, last 200 lines of the last hour), `Settings > Diagnostics` view and `Save report…` (App/Diagnostics/DiagnosticsSource.swift, App/Windows/DiagnosticsView.swift, App/Windows/SettingsView.swift)

## Phase 7: US6 App icon (FR-027, FR-028)
**Goal**: the app has an icon of its own.
**Independent test**: the built app shows the brain on a rounded square in Finder, privacy lists and notifications; the script regenerates it.
- [ ] T029 [P] [US6] `scripts/make-app-icon.swift`: draws the `brain` symbol in white on a rounded square with a single blue gradient (824 px square inside 1024, corner radius 185), writes the ten PNG sizes and `Contents.json` into `App/Resources/Assets.xcassets/AppIcon.appiconset` (scripts/make-app-icon.swift)
- [ ] T030 [US6] Run the script, commit the asset, set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml`, regenerate and build, look at the app in Finder (project.yml, App/Resources/Assets.xcassets/AppIcon.appiconset)

## Phase 8: Polish
- [ ] T031 Scale: coverage and absence work under 100 ms per first analysis on 10,000 items; backup of a 1 GB library under 2 minutes (a generated tree), off the main actor (Tests/HardeningScaleTests.swift)
- [ ] T032 Docs: `DEVELOPER.md` section "How hardening works", `docs/roadmap.md`, `CLAUDE.md` stack line, `specs/010-hardening/pr-description.md`
- [ ] T033 Full suite and app build; run in the app on the real library with permission, counts only: items flagged, a backup and restore on a copy, a notification, the diagnostics file searched for known strings, and a check that no network connection is opened during a backup, an export or a report (quickstart)

## Dependencies
- T001 first. T002 and T003 are independent of each other and block US1 (T003) and US3 (T002).
- US1: T004 → T005 → T006 → T007 → T008 → T009 → T010 → T011; T012 after T009.
- US2: T013 → T014; T015 → T016 → T017 → T018 → T019 → T020. US2 does not depend on T001 or US1 (sync state is in v11), so T013 to T018 can start at once.
- US3 needs T002, T009's runner edit (T022 shares `ImageAnalysisJob.swift`: do T009 first) and the `possibly-cancelled` count from T003.
- US4, US5 and US6 are independent of each other and of US1 to US3 (US5 reads sync and queue figures that exist already).
- T031 to T033 last.

## Parallel examples
- After T001: T002, T003, T013, T015, T024, T026 and T029 touch different files and can run together.
- US4, US5 and US6 can be built in any order by different sessions.

## Implementation strategy
MVP is US1 plus US2 (both P1): the first protects the calendar from false meetings, the second protects the library. Ship them first, then US3, then US4 to US6 as a small batch. Each phase leaves the app runnable and the suite green.
