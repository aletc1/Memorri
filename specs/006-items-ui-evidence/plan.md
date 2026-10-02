# Implementation Plan: See where every item comes from, fix it in place, and review the doubtful ones

**Branch**: `006-items-ui-evidence` | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/006-items-ui-evidence/spec.md`

## Summary

Three additions to the Items window of spec 005, on the existing items, sightings, observations, locks and operation log:

1. **Evidence.** After a capture is reconciled, an `EvidenceWriter` cuts the region around each sighting's cited OCR lines out of the full-size picture (union of the line boxes plus a margin, clamped, at most 1600 px wide) and saves it as a small HEIC under `evidence/`. A new `evidence` table links the cut-out to its item and keeps the sighting's date, display, title and box, so the evidence stays when the capture is deleted (clarification 4). It goes with the item and with "Delete everything". The detail view shows the 5 newest sightings with their cut-outs, and the whole capture (while stored) with the cited lines outlined.
2. **Review and the Inbox.** `ItemRecompute` also computes `needs_review` and its reasons on every change: confidence below 0.75, a guessed start, end or due as the chosen value, an open possible duplicate, or values changed since the user approved. New operations `approve` (with a snapshot of the read values) join the log and undo; an edit approves too. The Inbox is a filter of the Items window plus a menu entry with the count.
3. **Inline editing of every field.** Typed editors for title, start, end, all-day, due, reminder, people, place and notes call the existing `ItemOperations.edit` (locked user values), with added validation (start not after end, non-empty title). Kind filters split Tasks and Reminders.

Decisions are in [research.md](research.md); the architecture is ADR 0021 (Proposed).

## Technical Context

**Language/Version**: Swift 6 (6.4 toolchain), strict concurrency

**Primary Dependencies**: GRDB 7.11.1, Foundation, ImageIO/CoreGraphics for cropping (no new dependency), SwiftUI and AppKit. No model calls in this spec.

**Storage**: migration `"v6"`: table `evidence`; columns `needs_review`, `review_reasons_json`, `approved_at`, `approved_values_json` on `items`; index on `items(needs_review, status)`. Cut-out files under `<root>/evidence/YYYY-MM/<id>.heic` (mode 0700, excluded from backups with the root). See [data-model.md](data-model.md).

**Testing**: Swift Testing. Pure `EvidenceGeometry` (union, margin, clamp, scale) and `ReviewRules` tables; `EvidenceWriter` against drawn pictures in temporary folders; `ItemOperations` approve/edit/undo snapshot tests; `ItemListModel` filter, Inbox and editor validation; cleanup keeps cut-outs on retention and removes them on "Delete everything"; a scale test (5,000 items, 20,000 sightings).

**Target Platform**: macOS 26+, Apple silicon.

**Project Type**: desktop app (menu-bar agent) with the local core package.

**Performance Goals**: item detail with cut-outs under 1 s and the Inbox under 0.5 s with 5,000 items (SC-007); cut-outs written in the analyse job after reconciliation, a few ms each.

**Constraints**: local only, nothing new leaves the process; the analyse job never fails because of evidence (errors logged, the item still works); cut-outs must match the full-size picture's coordinates (OCR boxes are full-resolution pixels, top-left origin).

**Scale/Scope**: thousands of items, tens of thousands of sightings; a cut-out is about 20 to 80 KB.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | Cropping is local; no network. Synthetic pictures only in tests and the quickstart. |
| II. Every item carries evidence | Pass | This spec delivers the cropped evidence image the principle names, per sighting, with capture, lines and confidence. |
| III. Idempotent, no duplicates | Pass | Reanalysis replaces a picture's evidence with its sightings; approval and review do not create items. |
| IV. The user wins | Pass | Every field editable and locked; the Inbox is the confidence gate that spec 009 reads ("nothing below the threshold syncs without approval"). |
| V. Raw data kept, under user control | Pass, with a recorded choice | Cut-outs outlive their capture by design (clarification 4); they count in the storage figures and "Delete everything" removes them. ADR 0021. |
| VI. Test-first core | Pass | Geometry, review rules, writer, operations and list logic are core and test-first. No prompt changes. |
| VII. Incremental, always runnable | Pass | Ends with a runnable app; no sync. |
| VIII. Decisions recorded | Pass | ADR 0021 (evidence storage and review state). |

**Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/006-items-ui-evidence/
├── plan.md, research.md, data-model.md, quickstart.md
├── contracts/core-interfaces.md, contracts/ui-contract.md
├── checklists/requirements.md
└── tasks.md            # /speckit-tasks
```

### Source Code (repository root)

```text
App/
├── MenuContent.swift                     # "Inbox (N)" opens the Items window on the Inbox (edit)
├── AppEnvironment.swift                  # EvidenceWriter in the job, review count observation (edit)
├── AppState.swift                        # reviewCount (edit)
├── Windows/ItemsView.swift               # Inbox scope, kind filter with Reminders, review badges (edit)
├── Windows/ItemsViewModel.swift          # approve, field edits, evidence loading (edit)
├── Windows/ItemDetailView.swift          # field editors, evidence cards, show all (edit)
├── Windows/EvidenceViews.swift           # cut-out card and whole-capture sheet with outlines (new)
├── Windows/FieldEditor.swift             # typed inline editors (new)
└── Windows/StorageSettingsView.swift     # evidence figure (edit)
Packages/MemorriCore/Sources/MemorriCore/
├── Evidence/EvidenceGeometry.swift       # union, margin, clamp, scale (new)
├── Evidence/EvidenceWriter.swift         # cut, encode, save, insert; backfill (new)
├── Evidence/EvidenceStore.swift          # rows for an item, full-picture lines, sizes (new)
├── Reconciliation/ReviewRules.swift      # needs_review and reasons (new)
├── Reconciliation/ItemRecompute.swift    # computes review columns (edit)
├── Reconciliation/ItemOperations.swift   # approve, edit validation, edit approves (edit)
├── Reconciliation/OperationLog.swift     # approve kind; ItemState with approval (edit)
├── Reconciliation/ItemMerge.swift        # evidence follows moved sightings; review recompute (edit)
├── Reconciliation/ReconcilerApply.swift  # evidence of replaced sightings removed (edit)
├── Reconciliation/ItemListModel.swift    # Inbox scope, Reminders, review text, edit parsing (edit)
├── Analysis/ImageAnalysisJob.swift       # writes evidence after reconcile (edit)
├── Storage/Migrations.swift              # v6 (edit)
├── Storage/AppPaths.swift                # evidence folder (edit)
├── Storage/StorageStats.swift            # evidence bytes (edit)
└── Storage/CleanupService.swift          # delete-everything removes evidence (edit)
docs/architecture/decisions/0021-evidence-cut-outs-and-review-state.md (new)
```

**Structure Decision**: a new `Evidence` folder in `MemorriCore` (planned since the bootstrap); review logic sits with reconciliation because it is recomputed with the item.

## Complexity Tracking

No violations.
