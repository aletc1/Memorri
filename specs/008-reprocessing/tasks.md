# Tasks: reprocessing (spec 008)

## Phase 1: Storage (foundation)
- [ ] T001 Migration v10: `trials`, `trial_images`, `trial_findings`, `trial_differences`, `analysis_jobs.trial_id`, rebuild `reconcile_ops` kind check with `apply_trial`; test in Tests/StorageDatabaseTests.swift (Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift)
- [ ] T002 Records and `TrialStore` (create, cancel, resume, delete, observe, progress, out-of-date count) with tests first (Reprocessing/TrialStore.swift, Tests/TrialStoreTests.swift)

## Phase 2: US1 trials that touch nothing
- [ ] T003 [US1] Tests: runner stores proposals only, library snapshot identical, resume reads nothing twice, skipped and failed captures, priority below new captures (Tests/TrialRunnerTests.swift)
- [ ] T004 [US1] `TrialJobRunner` (kind `trial`): stored OCR, trial model settings, pipeline, store proposals; wire in AppEnvironment; exclude from capture overview counts
- [ ] T005 [US1] Pre-flight check (server up, model installed) in `TrialStore.create` path and App wiring

## Phase 3: US2 comparison
- [ ] T006 [US2] Reconciler: plan over given findings and context (dry run) without changing live behaviour; existing Reconciler tests stay green
- [ ] T007 [US2] Tests then `TrialComparison` (new, changed, unchanged, notFound, protected by lock/approval/dismissal, totals add up, two trials) and `TrialWords` (Tests/TrialComparisonTests.swift)

## Phase 4: US3 apply, undo, audit
- [ ] T008 [US3] Tests: apply one/capture/item/all, locks untouched, idempotent, re-check skips, undo restores snapshot exactly (Tests/TrialApplyTests.swift)
- [ ] T009 [US3] `OperationKind.applyTrial`, `TrialApplier`, undo case, evidence rewrite, item-history words (Reprocessing/TrialApplier.swift, Reconciliation/ItemUndo.swift, OperationLog.swift)

## Phase 5: UI (US1 to US4)
- [ ] T010 [US1] `ReprocessSection` in Settings > Analysis: start, model picker, prompt text, trials list with progress, cancel, resume, delete
- [ ] T011 [US2] `TrialComparisonSheet`: totals, compare-with, grouped differences with cut-outs, protected reasons
- [ ] T012 [US3] Apply selected / apply all unprotected, History list with Undo
- [ ] T013 [US4] Out-of-date count in the section

## Phase 6: Polish
- [ ] T014 Scale test (1,000 captures comparison under 5 s), logging without content, full test suite
- [ ] T015 Run in the app (quickstart), docs: DEVELOPER.md section, roadmap, CLAUDE.md, pr-description
