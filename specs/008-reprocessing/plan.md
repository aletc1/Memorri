# Implementation Plan: Reprocess captures and compare before applying

**Branch**: `008-reprocessing` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

## Summary
Trials read stored captures with another model into their own tables (`trials`, `trial_images`, `trial_findings`), through a new `trial` job kind that reuses the stored OCR text and stops after the pipeline. A pure comparison runs the reconciler's plan on the proposals (dry run) and classifies differences (new, changed, not found, protected). `TrialApplier` applies selected differences per sighting in one undoable `apply_trial` operation. The UI is a Reprocess section in Settings > Analysis. ADR 0025.

## Technical Context
**Language/Version**: Swift 6, SwiftUI plus AppKit, macOS 26+
**Primary Dependencies**: GRDB (existing); no new package
**Storage**: migration v10 (trial tables, `analysis_jobs.trial_id`, `reconcile_ops` kind check rebuilt)
**Testing**: Swift Testing with `ReconcileFixture`, `FakeModelChatting`, `FakeJobRunner`; golden eval unchanged (no prompt change in this spec)
**Target Platform**: macOS 26+
**Project Type**: desktop-app
**Performance Goals**: comparison of a 1,000-capture trial under 5 s; new captures never delayed (priority)
**Constraints**: local only; trials never write live tables; user values always win
**Scale/Scope**: about eight core files, one migration, one settings section and one sheet

## Constitution Check
I Local-first: only the local Ollama. II Evidence: proposals keep cited lines and window; applied sightings carry cut-outs via the evidence writer. III Idempotent: applying twice does nothing; no duplicates. IV User wins: protected differences cannot apply; locks respected by recompute. V Raw data: proposals are derived and deletable. VI Test-first: core tests precede code; no prompt/model default change here, so the eval gate is unaffected. VII Incremental: runnable at each story. VIII ADR 0025. Pass.

## Project Structure
```text
specs/008-reprocessing/  spec, plan, research, data-model, contracts/, quickstart, tasks
Packages/MemorriCore/Sources/MemorriCore/Reprocessing/
  TrialStore.swift  TrialJobRunner.swift  TrialComparison.swift  TrialApplier.swift  TrialWords.swift
Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift (v10)
Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ (plan over given findings; OperationKind.applyTrial; undo case)
Packages/MemorriCore/Tests/MemorriCoreTests/Trial*Tests.swift
App/Windows/ReprocessSection.swift, TrialComparisonSheet.swift; AnalysisSettingsView.swift; AppEnvironment.swift (runner wiring)
```
