# Research: hardening (spec 010)

## R1. What a calendar view really showed
Decision: `CoverageReader` derives coverage from what the analysis already reads: `DateResolver.headers` (the day columns, with `monthAssumed` and `monthConflict`), the window's visible boxes from spec 011 (`WindowReadingRecord.visible`), and the vertical time axis (hour labels in the left margin). A coverage record is a list of **spans** (absolute instants, one per visible day column) between the first and last hour label that is visible. Only week and day views (`calendarWeek`, `calendarDay`) produce coverage.
Rationale: spans in absolute instants cannot be confused by time zones (the item's time zone, the capture's zone and the Mac's zone all differ in this user's life). Hour labels bound the vertical range, so a view scrolled to 8:00-18:00 never says anything about 7:00. A header with `monthAssumed` or `monthConflict`, fewer than three hour labels, or a day column outside the visible part gives no span, so the detection errs toward silence.
Alternatives: day-level coverage only (flags meetings that were scrolled out of view); the vision model asked "is X still listed?" (slow, unmeasured, and a model change would need the eval harness); month views (cells truncate to "+3 more", so absence proves nothing; month views never produce coverage, which the spec's silence rule allows).

## R2. When a flag is raised
Decision: after a **first analysis** of a capture is reconciled (`ImageAnalysisJobRunner`, kind `analyse` only), `CancellationDetector.record(imageID:)` stores the capture's coverage and, for every active appointment of the same context (read from `image_context` at that time; a capture without a context records nothing) with a moment inside a span, no all-day flag, at least one earlier sighting in an image that has coverage, and no sighting in this image, an absence row (item, image, capture event, captured_at). An item is *possibly cancelled* when it has absences from two different capture events, both captured after its latest sighting and after `cancel_cleared_at`. A later sighting makes older absences not count (they stay as history until the next prune, deleted when the sighting is stored). The flag is a review reason computed in `ReviewRules`, so it follows the normal Inbox machinery, approved items included.
Rationale: first analysis only keeps re-read, reanalysis and trials from creating suspicions (FR-008): `force` and `reread` jobs may only delete absences their new sightings contradict. Using capture time (not analysis time) keeps a backlog analysed out of order correct. Requiring an earlier sighting in an image **with coverage** means items seen only on mail or chat screens are never flagged (spec edge case); the first benefit appears once an item has been seen in a view captured after this version.
Alternatives: flag after one absence (user chose two); keep a coverage table for old captures (no old data to read it from).

## R3. Decisions on a flagged item
Decision: `Cancelled` is `ItemOperations.dismiss` (so the sync entry is removed and undo works as today). `Still happening` is `approve` plus `cancel_cleared_at = now` and the item's absence rows deleted; the operation's undo detail stores the removed rows (as spec 008 does) so Undo restores the flag. After `Still happening` absences only count again once the item has a sighting captured after `cancel_cleared_at`.
Rationale: no new status, no new tombstone rules; spec FR-004/FR-005.

## R4. Notification grouping
Decision: `NewItemsNotifier` is an actor with a quiet period (20 s since the last addition, never later than 2 min after the first) fed by `ReconcileSummary.createdItemIDs` of first analyses. On firing it asks the library how many of those ids are still active and how many need review, and calls a `NoticeShowing` port. The app side adapts `UNUserNotificationCenter`, skips the notice when the Items window is frontmost, and asks macOS for permission at the first notice, never at launch. A click opens the Inbox (or all items when none need review) through `AppEnvironment.showItems`.
Rationale: counting at firing time reflects merges and approvals made meanwhile; first analyses only keeps re-read and trials silent (FR-012). Possibly cancelled items are counted from the review count difference: the notice also names how many *became* possibly cancelled in the burst (they need review).
Alternatives: one notice per capture (spam); a fixed timer (a burst longer than the timer splits).

## R5. Backup format and restore
Decision: a backup is a **package folder** `Memorri Backup <date>.memorribackup` holding `manifest.json` (format version, schema version, app version, created, includesPictures, file list with sizes and SHA-256), `memorri.sqlite` (made with GRDB's online `backup`, a consistent snapshot while the app works), `evidence/` and, when chosen, `captures/`. Copies use `copyItem` (clone on APFS), checked by the manifest. Restore validates the manifest, checksums and that the schema version is not newer than the app's, then **stages** the package into `restore-pending/` next to the library and asks to restart. `StorageBootstrap.start` finishes a staged restore **before** opening the database: the current `memorri.sqlite`, `evidence/` and `captures/` are moved into `safety-copies/<timestamp>/` (a rename within the volume), the staged files are moved into place, and a marker records the result. A failure at any step moves everything back.
Rationale: the live database pool and the queue hold the file open, so swapping it under a running app is the dangerous path; the launch swap needs no pausing, is atomic per step and testable on temporary directories. A missing `captures/` leaves restored captures without pictures, as the spec says.
Alternatives: close and reopen the pool in process (races with jobs and observers); a zip (slow to read back, needs a library); copying instead of renaming for the safety copy (doubles disk use).

## R6. Item export
Decision: one JSON file, version 1: items (all statuses) with fields, locks, review state, aliases, the sightings (title, captured_at, window app and title, cited text lines) and the sync state, no pictures and no evidence images. Written atomically; the open panel chooses the place.
Rationale: readable outside Memorri (spec FR-016); sightings carry the text that proves each item.

## R7. Launch at login
Decision: `SMAppService.mainApp` (`register`, `unregister`, `status`). The setting reads `status` on every open of the section: `.enabled` on, `.requiresApproval` shows the approval note with a button for `SMAppService.openSystemSettingsLoginItems()`, others off.
Rationale: the system owns the truth (SC-009); no stored copy to drift.

## R8. Diagnostics without content
Decision: the report is built from figures only (versions, permissions, job counts by kind and state, failure reasons, sync runs and problems, storage use). Log lines come from `OSLogStore(scope: .currentProcessIdentifier)` filtered to the subsystem `com.aletc1.memorri`, the last 200 at `info` or above from the last hour. `LogSanitiser` keeps only categories on an allow list and drops any line (and any failure reason) that contains a title, place, person, note or window title of the library (a lowercase substring test against those strings of at least 4 characters) or looks like an OCR line (more than 12 words). A test plants known strings in a library and searches the report.
Rationale: the strongest guarantee is that content is never an input of the builder; the sanitiser is the second wall for log lines whose text we do not control.
Alternatives: trust `privacy:` flags in log calls (a missed flag leaks); no log lines (less useful).

## R9. App icon
Decision: `scripts/make-app-icon.swift` (run with `swift scripts/make-app-icon.swift`) draws the SF Symbol `brain` in white on a rounded square with a single blue gradient (the macOS icon grid: 824 px square inside 1024, corner radius 185) and writes all ten PNGs plus `Contents.json` into `App/Resources/Assets.xcassets/AppIcon.appiconset`. `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.
Rationale: the menu-bar brain is a 36-pixel drawing that cannot be enlarged cleanly; the system brain symbol is the same subject and scales to any size. The script keeps the icon reproducible without a design tool.
Alternatives: upscale the menu-bar PNG (blurry); a hand-drawn vector (more than the user asked for).
