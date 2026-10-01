# Implementation Plan: Turn findings into one list of items without duplicates

**Branch**: `005-reconciliation` | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/005-reconciliation/spec.md`

## Summary

After the analyse job of spec 004 stores a picture's findings, a new `reconcile` step turns each finding into a **sighting** of one **item**. For every finding, code picks candidates (same context, same kind family, same day with overlapping or near times; for tasks, due within a day or both undated), scores each one from plain text similarity (normalised, truncation-aware), time agreement and, when the local embedding model is installed, the cosine of the two titles' embeddings. Clear matches merge, clear misses create an item, and the band in between is judged by the local reranker (`yes` probability). When the reranker is missing or fails, the finding becomes a new item flagged as a possible duplicate of the best candidate. No capture fails because of reconciliation.

All slow work (embeddings, reranker) happens before one write transaction that replaces the picture's earlier sightings and attaches the new ones, so a reanalysis keeps the same items (Constitution III). Each field of an item is chosen from its **observations** by the rule user > read > inferred > confidence > completeness > recency; a user edit becomes a locked user observation (Constitution IV). Dismissed items stay in the table as tombstones and still attract matching sightings, so the event never comes back. Every merge, split, dismissal, restore, edit and automatic merge is written to an **operation log** with what it changed, so any of them can be undone later, newest first or by itself when nothing later depends on it (clarification 1).

A minimal **Items window** opened from the menu bar lists items and offers merge, split, dismiss, restore, edit title, unlock and undo (clarification 3); spec 006 grows that window. `memorri-eval reconcile` scores a synthetic set of sighting sequences (true duplicates merged, wrong merges) without the vision model, and `memorri-eval run --reconcile` checks SC-007 end to end. Findings stored before this spec are not reconciled until their capture is analysed again (clarification 4).

Decisions are in [research.md](research.md); the architecture is ADR 0020 (Proposed).

## Technical Context

**Language/Version**: Swift 6 (6.4 toolchain), strict concurrency

**Primary Dependencies**: GRDB 7.11.1 (pinned), Foundation, SwiftUI and AppKit for the Items window. Ollama 0.34.4 on localhost for `/api/embed` (`jeffh/intfloat-multilingual-e5-large-instruct:f32`, 1024 dimensions) and `/api/generate` with `raw` and `logprobs` (`fanyx/Qwen3-Reranker-0.6B-Q8_0:latest`). Both installed on this Mac and checked by the spike (research R3, R4). No new third-party dependencies.

**Storage**: the existing SQLite database; migration `"v5"` adds `items`, `sightings`, `observations`, `item_aliases`, `field_locks`, `keep_apart`, `possible_duplicates`, `reconcile_ops`, `reconcile_op_items`, `title_embeddings`, and `reconciled_at` / `reconcile_error` on `image_analysis` ([data-model.md](data-model.md)). Sightings reference `capture_images` with `ON DELETE CASCADE`; items are recomputed after any cleanup.

**Testing**: Swift Testing in `Packages/MemorriCore/Tests`: table-driven `TitleSimilarity` and `TimeAgreement` cases, `FieldResolver` cases, `Reconciler` with a fake `MeaningJudging` (scripted cosine and reranker answers), the real database in temporary directories for store, undo and cleanup tests, and the sequence eval on the tracked synthetic set. The real models are covered by the spike and by `memorri-eval reconcile --models on`.

**Target Platform**: macOS 26+, Apple silicon.

**Project Type**: desktop app (menu-bar agent) plus the local core package and its `memorri-eval` tool.

**Performance Goals**: under 2 s added per capture on average without the reranker (SC-006); measured 18 ms for a warm embedding and 20 to 30 ms for a warm reranker call, about 1.1 s for the first call after load. Candidate lookup by indexed context, kind family and day, so thousands of items stay fast.

**Constraints**: local only (the spec 003 loopback transport); the serial queue from spec 003 runs one job at a time, so only manual operations can race with reconciliation, and the write transaction re-checks the items it touches; reconciliation never fails the analyse job; the vision model is not loaded or called by this step, and loading the matching models did not evict `qwen3-vl:8b-instruct` (research R12b); a context change on a picture reconciles it again (R12a).

**Scale/Scope**: tens of captures a day, a few to a few hundred findings each (month views), thousands of items over months. Items, observations and the log are small (kilobytes per item); embeddings are 4 KB per distinct title.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | Embedding and reranker calls go through the existing loopback-only transport to the local Ollama; nothing else leaves the process. Synthetic eval sequences only. |
| II. Every item carries evidence | Pass | Every field value is an observation linked to a sighting, which links to its picture and cited lines; inferred values are flagged and lose to read ones. Merge reasons (scores) are stored (FR-019). |
| III. Idempotent, no duplicates | Pass | Reanalysis replaces the picture's sightings in one transaction and scores against items as they were, so item ids survive; merges are logged and reversible. SC-003 is a test. |
| IV. The user wins | Pass | Edits become locked user observations; dismissed items are kept as tombstones and still match; a split writes `keep_apart`. Nothing syncs in this spec. |
| V. Raw data kept, under user control | Pass | Sightings cascade with their capture; items are recomputed after cleanup; user-touched items and tombstones remain. Storage figures unchanged in form. |
| VI. Test-first core, measured prompts | Pass | All matching and resolution code is pure and test-first. The reranker instruction is versioned (`rerank-v1`) and measured by `memorri-eval reconcile`; thresholds are set on the synthetic set and recorded. |
| VII. Incremental, always runnable | Pass | Ends with a runnable app (items appear in the Items window after analysis) and a runnable eval. No sync. |
| VIII. Decisions recorded | Pass | ADR 0020 (reconciliation: sightings, field observations, operation log, scoring with an optional reranker). ADR 0014 relied on. |

Technical constraints check: Swift 6, macOS 26+, GRDB with a migration, Ollama on localhost. **Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/005-reconciliation/
├── plan.md              # This file
├── research.md          # Decisions R1-R12b and the model spike
├── data-model.md        # Migration v5 tables, field rules, operation log
├── quickstart.md        # Validation scenarios
├── contracts/
│   ├── core-interfaces.md   # MemorriCore types and protocols
│   ├── eval-cli.md          # memorri-eval reconcile and run --reconcile, sequence case format
│   └── ui-contract.md       # Items window, menu item, log lines
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
App/
├── AppEnvironment.swift                 # wires ItemStore, Reconciler, OllamaMeaningJudge (edit)
├── MenuContent.swift                    # "Items…" opens the Items window (edit)
├── Windows/WindowCoordinator.swift      # new .items window id, resizable, size remembered (edit)
├── Windows/OllamaSettingsView.swift      # Matching models pickers (edit)
├── Windows/ItemsView.swift              # list, filters by kind and context, actions (new)
└── Windows/ItemDetailView.swift         # observations, aliases, locks, history with undo (new)
Packages/MemorriCore/Sources/MemorriCore/
├── Reconciliation/
│   ├── Item.swift                       # Item, ItemField, ItemStatus, KindFamily (new)
│   ├── TitleNormaliser.swift            # case, accents, punctuation, ellipsis (new)
│   ├── TitleSimilarity.swift            # prefix/truncation, edit distance, token overlap (new)
│   ├── TimeAgreement.swift              # candidate window and time score (new)
│   ├── MatchScorer.swift                # combines scores, thresholds, decision (new)
│   ├── MeaningJudging.swift             # protocol: embeddings and reranker (new)
│   ├── OllamaMeaningJudge.swift         # /api/embed, /api/generate with logprobs (new)
│   ├── FieldResolver.swift              # chooses each field from observations (new)
│   ├── Reconciler.swift                 # plan (async) then apply (one transaction) (new)
│   ├── ItemStore.swift                  # reads, recompute, cleanup sweep (new)
│   ├── ItemListModel.swift              # filters, sort, row text and enabled actions for the window (new)
│   ├── ItemOperations.swift             # merge, split, dismiss, restore, edit, unlock (new)
│   └── OperationLog.swift               # record and undo (new)
├── Analysis/ImageAnalysisJob.swift      # reconcile step after save (edit)
├── Settings/OllamaSettings.swift         # embedding and reranker model names (edit)
├── Inference/OllamaClient.swift         # embed and generate-with-logprobs calls (edit)
├── Storage/Migrations.swift             # v5 (edit)
├── Storage/CleanupService.swift         # sweeps items after deleting captures (edit)
└── Evaluation/
    ├── SequenceCase.swift               # sighting sequences and expected events (new)
    ├── SyntheticSequences.swift         # tracked generator (new)
    ├── ReconcileRunner.swift            # scores merges and wrong merges (new)
    └── EvalCommand.swift                # reconcile command, run --reconcile (edit)
Packages/MemorriCore/Tests/MemorriCoreTests/   # one test file per new type
eval/golden/synthetic-sequences/               # tracked synthetic sequences (new)
docs/architecture/decisions/0020-reconciliation-items-sightings-and-operation-log.md (new)
```

**Structure Decision**: the existing layout: app target in `App/`, logic in a new `Reconciliation` folder of `MemorriCore`, the eval inside `MemorriCore/Evaluation` and the `memorri-eval` executable (ADR 0015).

## Complexity Tracking

No violations.
