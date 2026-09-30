# Implementation Plan: Read captures and find appointments and tasks, measured against a golden set

**Branch**: `004-ocr-extraction-and-eval` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/004-ocr-extraction-and-eval/spec.md`

## Summary

Turn stored captures into findings. For every stored picture one durable `analyse` job (the queue from spec 003) does, in order: read the text with the system recogniser and store each line with its box; ask the local model what kind of screen it is and what environment it shows (first model call, small schema, also giving the visual tags); ask it for appointments, tasks, reminders and deadlines with a prompt and schema chosen by the kind (second call, which cites the numbered lines); then do everything that can be done without the model in plain, tested code: check the citations, resolve dates and times, guess missing end times from block geometry, derive the remaining tags, choose the context, and store the result in one transaction. A step that finished stays stored, so a retry resumes where the job stopped.

The model returns the literal text it sees ("tomorrow 10:00", "Wed") and the cited lines; it never does date arithmetic or invents boxes. `DateResolver`, `BlockGeometry`, `TagExtractor` and `ContextMatcher` are deterministic and test-first (Constitution VI). All of it sits behind one entry point, `AnalysisPipeline`, that the queue job and the new `memorri-eval` tool both call, so the tool measures exactly what the app runs. `memorri-eval` (an executable target inside the core package, because SwiftPM does not allow a target outside the package root) scores a golden set of synthetic, code-drawn cases for precision, recall, field accuracy, classification and tag accuracy, compares runs, sweeps picture sizes and refuses to run while the app's queue is busy. The size sweep sets the downscale default (ADR 0004).

Four short spikes come first (text recognition quality and speed, model with numbered lines and a picture, block geometry on drawn calendars, window titles from ScreenCaptureKit); see [research.md](research.md).

## Technical Context

**Language/Version**: Swift 6 (Swift 6.4 toolchain), strict concurrency

**Primary Dependencies**: Vision (`RecognizeTextRequest`, checked on this Mac), NaturalLanguage (`NLLanguageRecognizer`), Core Graphics and ImageIO, ScreenCaptureKit (already used), GRDB 7.11.1 (pinned). No new third-party dependencies; `memorri-eval` parses its own arguments.

**Storage**: the existing SQLite database; migration `"v3"` adds `contexts`, `context_hints`, `capture_windows`, `ocr_reads`, `ocr_lines`, `image_analysis`, `image_context`, `capture_tags`, `findings` and a `step` column on `model_runs` ([data-model.md](data-model.md)). Every table that belongs to a picture references `capture_images` with `ON DELETE CASCADE`, so the cleanup from spec 002 needs no change. Settings in `UserDefaults`; golden cases and run reports under `eval/`.

**Testing**: Swift Testing in `Packages/MemorriCore/Tests`: fake `TextRecogniser` and fake `ModelChatting` (scripted answers), the real database in temporary directories, drawn pictures for geometry, table-driven date and matcher cases. `scripts/fake-ollama.py` gets an `extract` mode that returns plausible findings for the quickstart. The real recogniser and model are covered by the spikes and the quickstart; golden scores are measured with the real model.

**Target Platform**: macOS 26+, Apple silicon; Ollama 0.34.4 with `qwen3.8:27b-mlx`.

**Project Type**: desktop-app (menu-bar agent) plus a local Swift package with a command-line tool

**Performance Goals**: stored capture to findings visible in under 3 minutes for one display with default settings (SC-008); the menu and Settings stay responsive (1 s) while recognition and model calls run (everything runs off the main actor inside the serial queue loop); reading a picture warm in a few seconds (measured by spike S1; the first call after launch is slow, 43 s observed).

**Constraints**: local only (spec 003 transport, ADR 0011); one job at a time (spec 003); every model answer checked against a schema; findings need valid cited lines; nothing real committed; no new network component; the capture step must not get slower in a way the user notices (window titles come from the list the capturer already fetches).

**Scale/Scope**: a few hundred lines of text per picture, 1 to 4 displays per capture, tens of captures a day. A stored picture's analysis data is tens of kilobytes; it expires with the capture (7 days by default).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | Recognition runs on the Mac; model calls go through the spec 003 loopback-only transport; window titles, tags and findings stay in the local database and expire with the capture; eval reads only local files and the local server; tracked golden cases are synthetic. |
| II. Every item carries evidence | Pass | Each finding keeps cited line numbers (whose boxes give the evidence crop later), its run (model, prompt and schema versions), per-field read or inferred marks with the rule used, and confidence. |
| III. Idempotent, no duplicates | Pass | One analysis per picture replaced on reanalysis (old run records kept); `(image_id, n)` keys for lines; retries resume and never double-insert (results stored in one transaction). Cross-capture merging is spec 005. |
| IV. The User wins | Pass | A context chosen by the user is stored with `source = user` and never overwritten; Pause and automatic-analysis switch from spec 003 and this spec; nothing syncs. |
| V. Raw data kept, under user control | Pass | OCR lines, window titles, tags, findings and raw answers are stored with their capture and removed by every kind of cleanup through the existing cascade; storage is visible in the existing Settings figures. |
| VI. Test-first core, measured prompts | Pass | Every core type is written test-first; this spec builds the harness itself, prompts and schemas are versioned, and the synthetic golden set becomes the gate for later prompt changes (DEVELOPER.md section 8). |
| VII. Incremental, always runnable | Pass | Ends with a runnable app that analyses captures and a runnable eval tool; no sync. Order inside the spec: eval and scoring first, then reading, classification, extraction, dates, durations, contexts, tags, size study. |
| VIII. Decisions recorded | Pass | ADR 0014 (one analysis pipeline, model returns literal text, code does the rest), ADR 0015 (eval harness in the core package, synthetic golden set), ADR 0016 (environment tags and context assignment), ADR 0017 (picture size default, written when the sweep ends). ADR 0004 is relied on, not changed. |

Technical constraints check: Swift 6, macOS 26+, GRDB with a migration, Vision plus Ollama with JSON-schema output, unnotarized. **Deviation from CLAUDE.md**: the tool lives at `Packages/MemorriCore/Sources/memorri-eval`, not `Tools/memorri-eval`, because a SwiftPM target cannot be outside the package root (checked on this Mac); `CLAUDE.md` and `DEVELOPER.md` are updated in the polish task. **Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/004-ocr-extraction-and-eval/
├── plan.md              # This file
├── research.md          # Decisions R1-R20 and the four spikes
├── data-model.md        # Migration v3 tables, findings, tags, settings
├── quickstart.md        # Validation scenarios
├── spike-report.md      # Written by the spike tasks
├── contracts/
│   ├── core-interfaces.md   # MemorriCore types and protocols
│   ├── eval-cli.md          # memorri-eval commands, golden case format, report format, metrics
│   └── ui-contract.md       # Settings → Analysis, menu, debug switch, log lines
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
App/
├── Adapters/ScreenCaptureKitCapturer.swift   # also returns window titles per display (edit)
├── AppEnvironment.swift                      # wires recogniser, pipeline, job runner, enqueue after capture (edit)
├── Windows/AnalysisSettingsView.swift        # Settings → Analysis: switch, recent captures, contexts (new)
├── Windows/SettingsView.swift                # adds the Analysis row (edit)
└── DebugIngest.swift                         # --ingest-picture <png>, Debug builds only (new)
eval/
├── golden/README.md                          # format and rules (edit)
└── golden/synthetic/<case>/{screenshot.png,meta.json,expected.json}   # generated, tracked (new)
scripts/fake-ollama.py                        # extract mode (edit)
Packages/MemorriCore/
├── Package.swift                             # adds the memorri-eval executable target and product (edit)
├── Sources/MemorriCore/
│   ├── Capture/
│   │   ├── DisplayCapturing.swift            # CapturedDisplay gains windows (edit)
│   │   └── CapturePipeline.swift             # stores windows, enqueues analysis (edit)
│   ├── Recognition/
│   │   ├── TextRecogniser.swift              # protocol, RecognisedLine, reading order, VisionTextRecogniser (new)
│   │   └── OCRStore.swift                    # ocr_reads and ocr_lines (new)
│   ├── Extraction/
│   │   ├── ScreenKind.swift                  # the seven kinds (new)
│   │   ├── Prompts.swift                     # versioned prompts per kind (new)
│   │   ├── Schemas.swift                     # classification and extraction schemas per kind (new)
│   │   ├── Findings.swift                    # FindingDraft, Finding, FieldOrigin, validation of citations (new)
│   │   ├── DateParser.swift                  # month and weekday names, numeric orders, en and es (new)
│   │   ├── DateResolver.swift                # rules, headers, time zones (new)
│   │   ├── BlockGeometry.swift               # hour scale fit, block bounds from pixels (new)
│   │   ├── TagExtractor.swift                # text- and capture-derived tags (new)
│   │   ├── ContextMatcher.swift              # hint scoring, tie rules (new)
│   │   └── AnalysisPipeline.swift            # the one entry point (new)
│   ├── Analysis/
│   │   ├── ModelStep.swift                   # shared model call: settings per attempt, run record with step (new, extracted from ModelTestJob)
│   │   ├── ImageAnalysisJob.swift            # `analyse` job runner (new)
│   │   ├── CompositeJobRunner.swift          # dispatch by job kind (new)
│   │   ├── AnalysisResultStore.swift         # transactional store of a result, reanalysis, backlog query (new)
│   │   └── AnalysisJobStore.swift            # enqueue(kind:) and backlog helpers (edit)
│   ├── Contexts/
│   │   └── ContextStore.swift                # contexts, hints, assignments (new)
│   ├── Evaluation/
│   │   ├── GoldenCase.swift                  # load and write cases (new)
│   │   ├── Matcher.swift                     # one-to-one matching, thresholds (new)
│   │   ├── Metrics.swift                     # precision, recall, field, classification, tag accuracy (new)
│   │   ├── EvalRunner.swift                  # runs the pipeline over cases, replay, size sweep (new)
│   │   ├── EvalReport.swift                  # report, JSON, comparison, text output (new)
│   │   ├── SyntheticCases.swift              # drawn cases with expected results (new)
│   │   └── BusyCheck.swift                   # refuses while the app queue has a running job (new)
│   ├── Settings/AnalysisSettings.swift       # automatic analysis switch (new)
│   └── Storage/Migrations.swift              # adds "v3" (edit)
├── Sources/memorri-eval/main.swift           # thin command-line front end (new)
└── Tests/MemorriCoreTests/                   # one test file per new type above
docs/architecture/decisions/                  # 0014, 0015, 0016 (proposed now), 0017 (from the size sweep)
```

**Structure Decision**: same two-part layout as specs 001 to 003. Everything with logic is in `MemorriCore` behind protocols (`TextRecogniser`, `ModelChatting`, `AnalysisJobStoring`), so every branch is unit-tested with fakes. The Vision recogniser, the ScreenCaptureKit window list, the settings view and the debug switch are the only parts that need the real system and are covered by the spikes and the quickstart. The eval tool is a thin front end over `Evaluation/` in the same package.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Two model calls per picture (classify, then extract) | Per-kind prompts need the kind first; the first call also gives the visual tags | One call with a generic prompt cannot read a calendar grid and a chat equally well (spec US4); the second call over the same picture is expected to be cheap because the server reuses its work (spike S2 measures it) |
| A second executable target | The constitution and spec US1 require a runnable harness | A test-only harness cannot compare runs, sweep sizes or be run by a developer against a model |
