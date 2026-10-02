# Implementation Plan: Read each window on its own

**Branch**: `011-window-aware-analysis` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/011-window-aware-analysis/spec.md`

## Summary

A capture is split into its visible windows from the stored stack and frames (`capture_windows`), with the text a window in front covers taken away. One model call ("windows", replacing "classify") sees every visible window and says, per window, whether it can hold events and what kind of view it is. Each relevant window is then read on its own: month grids by geometry (no call), everything else by one extraction call on the window's cut of the picture and its own lines. The date context (title, labels, headers, conflicts) and the reference clock come from the window and its surroundings only; a month or year nothing names, a conflict, or an unreadable or far-off clock flags the date as a guess. Findings carry their window; sightings and evidence copy its application and title. Evidence cut-outs show the finding's window (or, for a very large window, a 1400 x 800 area around the cited lines). One model (`qwen3-vl:8b-instruct`) does the sorting: it beat the alternative in a quick trial (research R11). After the update the library is re-read once in the background, behind new captures, reusing the stored text. Reconciliation (spec 005) and evidence and review (spec 006) run unchanged on the findings of all windows of a picture.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), macOS 26+

**Primary Dependencies**: GRDB (SQLite), Apple Vision (OCR, already stored per picture), Ollama on localhost (`qwen3-vl:8b-instruct`, ADR 0019) through the existing `ModelChatting`

**Storage**: SQLite: migration `v8` adds `window_readings`, a `window_key` on `findings`, window name columns on `sightings` and `evidence`, and a `priority` on `analysis_jobs`

**Testing**: `swift test --package-path Packages/MemorriCore` (Swift Testing), `memorri-eval run` on `eval/golden` with new multi-window synthetic cases

**Target Platform**: macOS 26+ menu-bar app

**Project Type**: desktop app with a local core package and an eval CLI

**Performance Goals**: model calls per capture ≤ 1 + relevant non-month windows (FR-011); average time per synthetic case at most +25% (SC-004); splitting into windows and date context under 50 ms per capture without the model

**Constraints**: local only (constitution I); no prompt change without the eval (VI); reconciliation and review code paths unchanged (spec 005/006); stored text reused, OCR never repeated for the library re-read

**Scale/Scope**: up to ~10 windows per display picture; libraries of thousands of captures for the re-read, at background priority

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I. Local-first and private | Pass | Window frames, titles and clocks come from the stored capture and the local model; window names never logged (FR-009, FR-014). |
| II. Every item carries evidence | Pass | Cut-outs stay inside the window they were read from (FR-013); sightings record their window. |
| III. Idempotent, no duplicates | Pass | Findings of all windows of one picture are reconciled together; the same event in two windows is one item (R7). The re-read replaces a picture's sightings, as reanalysis does today. |
| IV. The user wins | Pass | Locks, approvals and dismissals are untouched by the re-read (FR-011a, SC-009); guessed dates go to the Inbox. |
| V. Raw data kept | Pass | `window_readings` and each model run are stored; the re-read reuses stored text. |
| VI. Test-first, measured prompts | Pass with work | The windows prompt and per-window extraction are new prompt versions: eval before and after, per-case, with new cases (FR-012). Core logic (visibility, clock, conflicts) test-first. |
| VII. Incremental | Pass | Stories ship in order; a capture without a stack takes the old path. |
| VIII. Decisions recorded | Pass | ADR 0022 (window-aware analysis), linked from the spec; the postmortem of 2026-10-01 links here. |

Post-design re-check (after Phase 1): unchanged, all pass.

## Project Structure

### Documentation (this feature)

```text
specs/011-window-aware-analysis/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── core-interfaces.md
│   └── prompts-and-eval.md
└── tasks.md            # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/MemorriCore/Sources/MemorriCore/
├── Windows/                         # new
│   ├── VisibleWindows.swift         # stack + frames -> visible regions, lines per window, the desktop's own lines
│   ├── ReferenceClock.swift         # clock texts -> reference date and source (R4)
│   ├── WindowReading.swift          # per-window kind, relevance, date context, findings
│   └── WindowReadingStore.swift     # window_readings rows
├── Extraction/
│   ├── AnalysisPipeline.swift       # per-window flow; old single-picture path kept for no stack / failure
│   ├── DateResolver.swift           # conflict flag (FR-007), clock reference
│   ├── Prompts.swift, Schemas.swift # windows prompt (replaces classify for captures with windows), extraction per window
│   └── SubjectRegion.swift          # visibleLines moves to Windows/VisibleWindows
├── Analysis/
│   ├── ImageAnalysisJob.swift       # reuse stored window readings; job kind `reread`
│   ├── AnalysisJobStore.swift       # priority column, ordering
│   └── LibraryReread.swift          # one-off enqueue after the update (FR-011a)
├── Storage/Migrations.swift         # v8
├── Reconciliation/                  # sightings copy window app/title; same-picture rule scoped to a window
├── Evidence/                        # evidence copies window app/title; cut-out = the window or a 1400x800 area of it (geometry 3)
└── Evaluation/                      # multi-window synthetic cases, per-window scores

App/Windows/EvidenceViews.swift      # window name on each card (US4)
```

**Structure Decision**: one new folder `Windows/` in the core for the window model, clock and per-window reading; the pipeline keeps its file and gains a per-window path beside the existing one.

## Complexity Tracking

| Choice | Why needed | Simpler alternative rejected because |
|---|---|---|
| Keeping the old single-picture path beside the per-window one | Captures without a stack and a failed windows call must give today's results (FR-010, edge case) | Treating every capture as one synthetic window changes old results (the classify prompt differs from the windows prompt) |
| A `priority` column on jobs | The library re-read must never delay new captures (FR-011a) | Dating background jobs in the future (`not_before`) makes them wait even when the queue is idle |
