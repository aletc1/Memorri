# Implementation Plan: Capture every display and keep the captures

**Branch**: `002-capture-and-storage` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-capture-and-storage/spec.md`

## Summary

Turn the "capture request" from spec 001 into a real capture. One request photographs each distinct display separately (no pointer) through ScreenCaptureKit, encodes a full-resolution HEIC and a downscaled analysis copy per display, and stores the result as one atomic unit: files staged in a temporary folder, moved into place, then the records written to a SQLite database (GRDB) in one transaction. Records and pictures live in one private folder under Application Support, excluded from backups.

The real capture is now the source of truth for the Screen Recording permission: a refused capture marks the permission "not granted" and opens the onboarding window; a successful one marks it "granted". Results are shown as a line at the top of the menu with a warning flash and sound on problems. Settings gets a real Storage section (counts, space used, delete older than N days, delete all captures, retention policy, analysis copy size). Retention and every cleanup touch captures only, never anything derived from them (ADR 0010).

All logic (pipeline, encoding, storage, retention, settings rules) lives in `MemorriCore` and is written test-first; ScreenCaptureKit, the disk-space query and the UI are thin adapters. See [research.md](research.md) for the decisions and the spikes that must prove the platform assumptions first.

## Technical Context

**Language/Version**: Swift 6 (Swift 6.4 toolchain), strict concurrency

**Primary Dependencies**: ScreenCaptureKit, ImageIO and CoreGraphics (HEIC encoding and downscaling), SwiftUI/AppKit, [GRDB.swift](https://github.com/groue/GRDB.swift) pinned to exactly 7.11.1, KeyboardShortcuts 2.4.0 (already pinned). No other third-party dependencies.

**Storage**: SQLite through GRDB `DatabasePool` (WAL), plus picture files, in `~/Library/Application Support/Memorri/`. Settings in `UserDefaults` (keys in the [UI contract](contracts/ui-contract.md)).

**Testing**: Swift Testing in `Packages/MemorriCore/Tests`: synthetic images, temporary directories, a fake display capturer, a fake clock and a fake disk-space checker. Platform behaviour (real displays, permission revocation, backup exclusion) is verified with spikes and the [quickstart](quickstart.md), using the UI automation now available on the developer Mac.

**Target Platform**: macOS 26+, Apple silicon. This Mac has three 3440×1440 displays, which is the multi-display test bench.

**Project Type**: desktop-app (menu-bar agent) plus a local Swift package

**Performance Goals**: feedback within 2 s of the key press with up to three displays (SC-001), so the three displays are encoded in parallel; menu and Settings stay responsive (under 1 s) during a capture (SC-009), so the work runs off the main actor.

**Constraints**: no network (FR-020); unsandboxed; data folder mode 0700 and excluded from backups; free-space floor 1 GB; one capture at a time; nothing half-written survives a crash or a failure.

**Scale/Scope**: a few hundred captures a day at most; up to three displays per capture; retention default 7 days. Rough size to validate in spike S3: about 2 MB per display per capture, so a heavy day is well under 1 GB and the 7-day default bounds it further.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | Files and database stay in a 0700 folder excluded from backups; no network code (source scan test from 001 keeps running over the new code); nothing leaves the Mac. |
| II. Every item carries evidence | Pass (enabling) | No items yet. This spec makes evidence possible: pictures are stored at full resolution with stable paths, and ADR 0010 requires items to keep their own evidence crops independent of the capture. |
| III. Idempotent, no duplicates | Pass | One request gives one event; concurrent requests are ignored (FR-011); mirrored displays are captured once; a failed attempt leaves nothing half-saved. |
| IV. The User wins | Pass | Deleting is always confirmed with counts; cancel changes nothing; items found in captures are never deleted (FR-023). |
| V. Raw data kept, under user control | Pass | This is the spec that delivers it: storage size visible, age cleanup, delete all, retention policy. |
| VI. Test-first core, measured prompts | Pass | Pipeline, encoder, store, retention, cleanup and settings rules are core code with tests written first. No prompts yet. |
| VII. Incremental, always runnable | Pass | Ends with a runnable app that really captures and stores; sync and analysis are untouched. |
| VIII. Decisions recorded | Pass | New ADRs 0009 (storage layout and atomic writes) and 0010 (only captures expire; items keep their own evidence), both Proposed here; ADR 0003 (GRDB) and 0004 (per-display capture) are relied on. |

Technical constraints check: SQLite through GRDB with migrations (ADR 0003); Swift 6, macOS 26+; unnotarized. All consistent. **Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/002-capture-and-storage/
├── plan.md              # This file
├── research.md          # Phase 0 output (decisions and spikes)
├── data-model.md        # Phase 1 output (schema, files, states)
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── ui-contract.md           # menu line, Storage section, messages, settings keys
│   └── core-interfaces.md       # MemorriCore protocols and types
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
project.yml                          # unchanged (GRDB 7.11.1 exact is added to the MemorriCore package only)
App/
├── AppEnvironment.swift             # wires the pipeline, store, retention and settings (edit)
├── AppState.swift                   # adds the last capture result and a clock tick (edit)
├── MenuContent.swift                # top line "Last capture: …" (edit)
├── Adapters/
│   ├── ScreenCaptureKitCapturer.swift   # DisplayCapturing with ScreenCaptureKit (new)
│   ├── DiskSpaceAdapter.swift           # free-space query (new)
│   └── FeedbackAdapter.swift            # adds the warning flash and sound (edit)
└── Windows/
    └── SettingsView.swift               # Storage section replaces the placeholder (edit)
    └── StorageSettingsView.swift        # counts, cleanup, retention, copy size (new)
Packages/MemorriCore/
├── Package.swift                    # adds GRDB dependency (edit)
├── Sources/MemorriCore/
│   ├── Capture/
│   │   ├── CaptureRequestService.swift  # now delegates to the pipeline, plays feedback by outcome (edit)
│   │   ├── CapturePipeline.swift        # disk check, capture, encode, stage, commit (new)
│   │   ├── DisplayCapturing.swift       # protocol, CapturedDisplay, CaptureFailure (new)
│   │   ├── CaptureOutcome.swift         # complete, partial, failed, permissionDenied, and LastCaptureResult (new)
│   │   └── ImageEncoding.swift          # HEIC encode and downscale (new)
│   ├── Storage/
│   │   ├── AppPaths.swift               # data folder, creation, 0700, backup exclusion (new)
│   │   ├── StorageDatabase.swift        # open, migrate, newer-version and damaged-file handling (new)
│   │   ├── Migrations.swift             # registerMigration "v1" (new)
│   │   ├── CaptureStore.swift           # records: insert, list, delete, counts (new)
│   │   ├── CaptureFileStore.swift       # staging, commit, delete, sweep of leftovers (new)
│   │   ├── StorageStats.swift           # counts and bytes for the Storage section (new)
│   │   ├── CleanupService.swift         # delete older than N days, delete all (new)
│   │   └── RetentionService.swift       # apply the policy at launch and daily (new)
│   ├── Permissions/
│   │   └── PermissionMonitor.swift      # adds captureSucceeded and captureDeniedByPermission (edit)
│   └── Settings/
│       └── StorageSettings.swift        # copy size and retention rules with validation (new)
└── Tests/MemorriCoreTests/              # one test file per new type above
```

**Structure Decision**: same two-part layout as spec 001. `CapturePipeline` depends only on protocols (`DisplayCapturing`, `ImageEncoding`, `DiskSpaceChecking`, stores, `TimeSource`), so the whole flow, including every failure path, is unit-tested with fakes and temporary directories. `ScreenCaptureKitCapturer` and the UI are the only parts that need a real screen, and they are covered by spikes and the quickstart.

## Complexity Tracking

No constitution violations. One added dependency (GRDB) is already decided in ADR 0003.
