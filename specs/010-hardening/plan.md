# Implementation Plan: Hardening for daily use

**Branch**: `010-hardening` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**ADRs**: 0027 (calendar coverage, absences and staged restore); builds on 0020, 0021, 0022, 0025, 0026

## Summary
Six independent pieces, shipped in the spec's priority order, each runnable on its own:
1. **Cancellation detection (P1).** The analysis records, for each captured week or day view, the instants the view really showed (`calendar_coverage`). After a new capture is reconciled, `CancellationDetector` writes an absence (`cancel_absences`) for every appointment of that context that fell inside the shown instants and has no sighting in the capture. Two absences from different capture events after the item's last sighting add the review reason `Possibly cancelled` (a new `ReviewRules` input). `Cancelled` is the existing `Dismiss`; `Still happening` is `Approve` plus a cleared-at mark. ADR 0027.
2. **Export, backup and restore (P1).** `ItemExporter` writes one JSON file. `LibraryBackup` writes a package folder (SQLite online backup, evidence, optionally captures, a manifest with checksums). Restore is staged and finished at the next launch, before the database opens: the current library is moved aside as a safety copy (a rename, so it costs no space), the backup takes its place. ADR 0027.
3. **Notifications (P2).** `NewItemsNotifier` (pure core: a quiet period that groups bursts) fed by the reconcile summaries of first analyses only; the app shows a `UNUserNotification` when the Items window is not in front.
4. **Launch at login (P3).** `LoginItem` over `SMAppService.mainApp`, behind a protocol.
5. **Diagnostics (P3).** `DiagnosticsReport` (pure builder over figures) with a `LogSanitiser`; the log comes from `OSLogStore` for this process and subsystem.
6. **App icon (P3).** `scripts/make-app-icon.swift` draws the system brain symbol in white on a rounded gradient square at every size into `AppIcon.appiconset`; `project.yml` names it.

## Technical Context
**Language/Version**: Swift 6, SwiftUI plus AppKit, macOS 26+
**Primary Dependencies**: system frameworks only: UserNotifications, ServiceManagement, OSLog; GRDB (already) for the online backup. No package added.
**Storage**: migration v12 (`calendar_coverage`, `cancel_absences`, `items.cancel_cleared_at`); settings key `notifications.enabled`; backup packages and safety copies on disk
**Testing**: Swift Testing; synthetic calendar sequences (extends `memorri-eval reconcile` data) for SC-001; fakes for the notification centre, login item and log store; a planted-strings test for diagnostics (SC-008); a restore swap tested on temporary directories
**Project Type**: desktop-app
**Performance Goals**: coverage and absence work adds under 100 ms to a first analysis on a library of 10,000 items; backup of about 1 GB under 2 minutes, off the main actor, with progress and cancel
**Constraints**: nothing is ever dismissed, deleted or unsynced by a suspicion; restore never leaves the library half replaced; no network; no captured text in diagnostics
**Scale/Scope**: about eight core files, one migration, four small app views (settings sections), one script, an icon asset

## Constitution Check
I Local-first: every file goes where the user picks; notifications are local; diagnostics hold no content and send nothing. II Evidence: a suspicion shows the last sighting and the capture that covered the item without it. III Idempotent: absences are keyed by item and image and recomputed only on first analysis; re-read and reprocessing add none. IV User wins: a suspicion only flags; `Cancelled` and `Still happening` are the user's own, undoable operations; locked values stay. V Raw data: backup and safety copies keep captures under the user's control; storage shows safety copies. VI Test-first: detector, rules, notifier, backup and report are pure or fake-backed and tested before the app wiring; no prompt change (the coverage is read from OCR headers, not from the model). VII Incremental: the six stories ship in order; the plan's phases follow. VIII ADR 0027. Pass.

## Project Structure
```text
specs/010-hardening/  spec, plan, research, data-model, contracts/, quickstart, tasks
Packages/MemorriCore/Sources/MemorriCore/
  Reconciliation/CalendarCoverage.swift   CancellationDetector.swift   (+ ReviewRules, ItemRecompute, ItemOperations, ItemUndo edits)
  Extraction/CoverageReader.swift         (coverage from headers, visible parts and the time axis; AnalysisResult gains `coverage`)
  Notifications/NewItemsNotifier.swift    NotificationWords.swift
  Backup/ItemExporter.swift  LibraryBackup.swift  LibraryRestore.swift  SafetyCopies.swift
  Diagnostics/DiagnosticsReport.swift  LogSanitiser.swift
  Lifecycle/LoginItem.swift
  Storage/Migrations.swift (v12)   Storage/StorageBootstrap.swift (finish a staged restore before opening)
Packages/MemorriCore/Tests/MemorriCoreTests/Coverage*Tests.swift Cancellation*Tests.swift NewItemsNotifierTests.swift Backup*Tests.swift Restore*Tests.swift Diagnostics*Tests.swift LoginItemTests.swift
App/Backup/ (panels)  App/Diagnostics/ (OSLogStore reader)  App/Notifications/NotificationCentreAdapter.swift  App/Login/ServiceManagementLoginItem.swift
App/Windows/ItemDetailView.swift (suspicion block)  App/Windows/StorageSettingsView.swift (backup, export, restore, safety copies)  App/Windows/GeneralSettings (login, notifications)  App/Windows/DiagnosticsView.swift
scripts/make-app-icon.swift   App/Resources/Assets.xcassets/AppIcon.appiconset   project.yml (AppIcon name)
```

## Phases
1. **Foundation** (v12, rule input, `ReconcileSummary.createdItemIDs`).
2. **US1 cancellation** (coverage reader, detector, rule, decisions, detail block, synthetic sequences in eval).
3. **US2 backup and restore**.
4. **US3 notifications**.
5. **US4 login, US5 diagnostics, US6 icon** (independent of each other).
6. **Polish**: docs, scale test, run on the real library (counts only, with permission).
