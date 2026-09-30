---

description: "Task list for spec 004: read captures and find appointments and tasks, measured against a golden set"
---

# Tasks: Read captures and find appointments and tasks, measured against a golden set

**Input**: Design documents from `/specs/004-ocr-extraction-and-eval/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. What needs the real recogniser, the real model or the real screen is proven by the spikes (Phase 1) and the quickstart scenarios; everything else is tested against fakes and drawn pictures.

**Organization**: Grouped by user story, in the order the stories can be built and verified. The eval harness (User Story 1) comes first because it measures everything after it. Story numbers follow the spec, so Phase 5 (User Story 4, classification) comes before Phase 6 (User Story 3, extraction): extraction needs the kind. Paths follow the layout in plan.md (`App/`, `Packages/MemorriCore/`, `eval/`, `scripts/`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 eval harness, US2 reading text, US3 findings, US4 screen kinds, US5 dates, US6 durations, US7 contexts, US8 tags, US9 picture size
- Commands assume the repository root as the working directory.
- **Privacy**: never open, read or screenshot real captures. Scenarios use drawn pictures and the debug ingest switch; the user's real capture folder is not touched.

## Phase 1: Setup and spikes

**Purpose**: Prove on this Mac what only the real system can answer, and prepare the stand-in server, before anything is built on the answers (lesson from specs 001 to 003). The spikes use drawn pictures only; never open or read real captures. Throwaway scripts stay in the scratchpad and are not committed; only `spike-report.md` is.

- [x] T001 Spike S1: write a throwaway Swift script in the scratchpad that draws five synthetic pictures with Core Graphics and Core Text (week calendar with hour labels and three blocks, email list with a line "Anna needs the report by Friday", dark chat, plain document, month grid) at 2400 x 1500, saves each native and degraded the way a remote session degrades (scaled to 75%, JPEG quality 0.4), and reads each with `RecognizeTextRequest` (accurate, automatic language) with language correction on and off; print per picture the exact-text rate against the known strings, whether every box overlaps its drawn text, and warm seconds (second call in the same process; the first call after start took 43 s on 2026-09-30)
- [x] T002 [P] Spike S4: write a throwaway script that calls `SCShareableContent.current` and prints, for the on-screen windows at layer 0 of each display, only counts and application names (never window titles, which can show the user's content): how many windows, how many have a non-empty title, whether a browser, Mail, Calendar and any remote-desktop client appear, and the milliseconds the call adds; note what a full-screen remote client reports as application name if one is installed
- [x] T003 [P] Extend `scripts/fake-ollama.py` with modes that answer by the request's `format` schema: a schema with `screen_kind` gets a valid classification, one with `findings` gets valid findings that cite lines 1 and 2, and the test schema keeps its answer; new modes `extract` (valid), `extract-bad-citation` (one finding cites line 9999), `extract-empty` (no findings) and `classify-unsure` (kind `other`, confidence 0.2); the existing `invalid`, `slow`, `error`, `flaky` and `hang` apply to every call; document the modes in the file header
- [x] T004 Spike S2: with the pictures from T001 and their lines numbered as `L<n> (x%,y%) text`, run the real model (`qwen3.8:27b-mlx`, native `format`, JPEG copy at 2048, think off) for the classification call and the extraction call on each picture, 5 runs each: record the valid-answer rate, the share of findings whose citations exist, the classification accuracy, the time of the second call sent right after the first with the picture first versus the text first in the message, and whether adding the position percentages changes citation accuracy; also one run each at 1536 and 3072
- [x] T005 [P] Spike S3 (may copy the drawing code of T001): prototype the block-height method from research R7 in a throwaway script on drawn week views in five styles (solid blocks, outlined blocks, rounded corners, overlapping blocks, dark theme) with blocks of 30, 60, 90 and 120 minutes, native and degraded (75%, JPEG 0.4): hour-scale fit from label lines, colour region around the first cited line, height to minutes rounded to 15; record how often a value comes back and the error in minutes per style
- [x] T006 Write `specs/004-ocr-extraction-and-eval/spike-report.md` from T001, T002, T004 and T005: a table per spike and the decisions they set: recognition settings (language correction on or off), message order and line detail for the two model calls, the classification confidence below which a picture counts as `other` (start from 0.5), which block styles use geometry and which fall back to the default, whether window titles are usable and what a remote client reports; update `research.md` R1, R3, R7 and R9 and `contracts/core-interfaces.md` where a decision changes them, and complete ADR 0014 with the measured second-call cost

**Checkpoint**: `spike-report.md` holds measured decisions; the fake server answers every call shape in every mode.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Migration v3, the shared model step, job dispatch by kind, the eval target and the fakes that every story needs. Tests first, then code. Tasks that edit `Fakes.swift` are not marked parallel.

- [x] T007 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v3"` per `data-model.md`: the tables `contexts`, `context_hints`, `capture_windows`, `ocr_reads`, `ocr_lines`, `image_analysis`, `image_context`, `capture_tags`, `findings` exist with exactly the listed columns and NOT NULL flags; every picture-owned table has a foreign key to `capture_images` with `ON DELETE CASCADE`, and deleting a capture leaves no row in any of them while `contexts`, `context_hints` and other captures stay; `image_context.context_id` is `ON DELETE SET NULL`; `ocr_lines` primary key is `(image_id, n)` and `capture_tags` primary key is `(image_id, key, value)`; `capture_tags` has no CHECK on `key`; `findings.kind`, `image_analysis.screen_kind`, `image_analysis.timezone_source`, `context_hints.kind` and `image_context.source` are constrained; context names are unique ignoring case; `model_runs.step` exists with default `test` and old rows read as `test`; a v2 database gains the v3 tables without losing captures, jobs or runs
- [x] T008 Implement migration `"v3"` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift` per `data-model.md` (new tables, indexes `context_hints(context_id)`, `capture_windows(image_id)`, `findings(image_id)`, `findings(start_at)`, unique index on `lower(contexts.name)`, `ALTER TABLE model_runs ADD COLUMN step TEXT NOT NULL DEFAULT 'test'`); the tests pass and databases with unknown migrations are still refused untouched
- [x] T009 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowTypesTests.swift` and extend `StorageDatabaseTests.swift`: `PixelBox` has `midX` and `midY` and encodes and decodes; `WindowInfo` holds application name, bundle id, title and a `PixelBox` frame; `CapturedDisplay.windows` defaults to empty so existing fakes compile; `CaptureStore` writes windows with the images in the same transaction (`insert(event:images:windows:)` keeps the old form working), reads them back with `windows(imageID:)` in `z` order, and deleting the capture removes them
- [x] T010 Implement `PixelBox` (`Packages/MemorriCore/Sources/MemorriCore/Recognition/PixelBox.swift`), `WindowInfo` (`Packages/MemorriCore/Sources/MemorriCore/Capture/WindowInfo.swift`), the `windows` field on `CapturedDisplay`, windows in `CaptureStoring.insert` and `CaptureStore` reading and writing `capture_windows`; the tests pass (the capture pipeline and the adapter use them in Phase 9)
- [x] T011 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ModelStepTests.swift` and extend `ModelTestJobTests.swift`: `ModelStep.call` reads model, think, timeout and the chosen model's thinking support once per attempt, takes JPEG bytes, sends a `ChatRequest` with the native `format` and temperature 0, maps client errors exactly as `ModelTestJobRunner` does today (timeout to `transient("timed out")`, 500 to `transient("server error 500")`, 400 to `permanent("request rejected")`, refused connection or missing model to `serverUnavailable`), validates the answer against the given schema (`invalid answer` is transient) and returns the parsed `JSONValue`, the raw answer and a `StepRecord`; `ModelRunRecord` has `step` and the test job still writes `test`; the request JSON never contains picture data
- [x] T012 Implement `ModelStep` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ModelStep.swift` (the model call extracted from `ModelTestJob.swift`, with `ModelChatting` and `ModelStepSettings`), add `step` to `ModelRunRecord` in `AnalysisJobStore.swift`, make `OllamaClient` conform to `ModelChatting`, and make `ModelTestJobRunner` use `ModelStep`, and add `PictureConverter.jpegData(from:longEdge:)` (downscale to a given longer side, JPEG 0.9) with a test, for the 1024-pixel classification copy decided in the spike report; all spec 003 tests still pass
- [x] T013 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/CompositeJobRunnerTests.swift` and extend `AnalysisQueueTests.swift`: `CompositeJobRunner` sends a job to the runner registered for its `kind` and returns `permanent("unknown job kind")` for another; `AnalysisQueue.enqueue(kind:imageID:)` creates a waiting job of that kind and wakes the loop; `AnalysisQueue` conforms to `AnalysisEnqueuing` and `enqueueAnalysis(imageIDs:)` creates one `analyse` job per id, in order
- [x] T014 Implement `CompositeJobRunner` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/CompositeJobRunner.swift`, the `AnalysisEnqueuing` protocol and `AnalysisQueue.enqueue(kind:imageID:)` with the conformance in `AnalysisQueue.swift`; the tests pass
- [x] T015 Add the `memorri-eval` executable target and product to `Packages/MemorriCore/Package.swift` with `Sources/memorri-eval/main.swift` that prints usage when no command is given; confirm `swift run --package-path Packages/MemorriCore memorri-eval` runs, that `xcodegen generate` and the app build are unaffected (the app does not link the tool), and that `.gitignore` ignores `eval/out/` and real golden cases and tracks `eval/golden/synthetic/`
- [x] T016 Add to `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift`: `FakeModelChatting` (scripted answers chosen by the schema's property names, records requests, optional delay and errors) and a `makePipelineFixture` helper that builds a temporary database with one stored capture and its pictures; `FakeTextRecogniser` (scripted lines or an error, counts calls) is added with `TextRecogniser` in the reading task of Phase 4, because it needs that protocol; no test depends on the real recogniser or the real server

**Checkpoint**: `swift test` passes with the v3 tables, the shared model step and job dispatch; the eval target builds.

---

## Phase 3: User Story 1 - Measure extraction quality before trusting it (Priority: P1) 🎯 MVP

**Purpose**: **Goal**: `memorri-eval` scores golden cases (precision, recall, field accuracy, classification and tag accuracy), compares runs, generates the synthetic set and refuses to run while the app is busy. The real pipeline is connected in Phase 6; until then the runner works against a fake analyser.

- [x] T017 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/GoldenCaseTests.swift`: a folder with `screenshot.png`, `meta.json` and `expected.json` loads (capture time with offset, Mac time zone, optional context with hints, optional windows, display size and scale, `origin`, optional expected tags, optional expected context, optional `lines` list of expected text strings, findings with kind, title, start, end, all-day, due, remind, people, place and `inferred` list); writing then loading is identical; a missing file or unknown `screenKind` gives an error naming the case; a folder without a picture is skipped with a warning; `origin` defaults to `local` when absent
- [x] T018 [US1] Implement `GoldenCase` (load and write, the JSON shapes in `contracts/eval-cli.md`, plus the optional `lines` list (text and box) in `expected.json`, which is already in that contract) in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/GoldenCase.swift`; the tests pass
- [x] T019 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/MatcherTests.swift`: exact title; different case and punctuation; one title containing the other; 79% and 81% similarity around the 0.80 threshold; start exactly 5 minutes away matches and 5 minutes 1 second does not; due date for tasks; kind mismatch never matches; two similar found items against one expected item give one match (the closer wins) and one unexpected; ties go to the higher similarity; all-day items match on the date
- [x] T020 [US1] Implement `Matcher` (normalised edit distance after lowercasing and removing spaces and punctuation, the containment rule, the time tolerance, one-to-one best-score assignment, constants `titleSimilarity = 0.80` and `minutes = 5` exposed and printed in reports) in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/Matcher.swift`; the tests pass
- [x] T021 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/MetricsTests.swift`: a perfect case gives precision, recall and field accuracy 1; one missing expected finding lowers recall and is listed; one extra found finding lowers precision and is listed with the closest expected one; field accuracy counts `start`, `end`, `allDay`, `due`, `remind`, `people` as a set, `place` normalised and the `inferred` flags over matched findings only; nothing found and nothing expected gives precision 1 and recall 1; classification accuracy; tag accuracy per key with wrong and missing counts (case-insensitive); context accuracy; OCR exact-text rate and box-overlap rate (at least 50% of the smaller box) when expected `lines` exist; disagreements where a finding's title does not appear (after normalising) in the text of its cited lines are counted and listed; results by kind, by origin and by confidence band (below 0.6, 0.6 to 0.85, above)
- [x] T022 [US1] Implement `Metrics` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/Metrics.swift`; the tests pass
- [x] T023 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvalReportTests.swift`: the report encodes to the JSON shape in `contracts/eval-cli.md` and decodes back; comparing two reports gives the difference per overall measure and names the cases whose score changed; the text output prints the thresholds, the overall line, per-kind and per-tag lines, the missed, unexpected and disagreement lists and the `ranWhileAppBusy` flag; a report containing `local` cases refuses to be written under `eval/golden/synthetic/`
- [x] T024 [US1] Implement `EvalReport` (JSON, comparison, text output) in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalReport.swift`; the tests pass
- [x] T025 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/BusyCheckTests.swift`: no database file is not busy; a database with a `running` job is busy; only `waiting`, `finished` and `failed` jobs are not busy; an unreadable or damaged file is not busy; the check opens the file read-only and leaves its bytes unchanged
- [x] T026 [US1] Implement `BusyCheck` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/BusyCheck.swift` (read-only GRDB connection to the path from `AppPaths.standard()` or a given URL); the tests pass
- [x] T027 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SyntheticCasesTests.swift`: `SyntheticCases.all` has at least 26 cases; every screen kind appears at least twice; there are cases for relative dates, header-column dates, "X needs Y", blocks of 30, 60, 90 and 120 minutes, a text-only meeting without an end, a capture just after midnight in a zone whose date differs from the Mac's, a 12-hour and a 24-hour clock, English and Spanish, a remote-desktop frame, Outlook-like, Apple Mail-like, Teams-like and plain web looks, an empty picture and a text-free picture; generating twice into two folders gives identical bytes; every `meta.json` and `expected.json` decodes; every picture is not blank and matches `displaySize`; every case has `origin = synthetic` and expected `lines` (text and drawn box) for the text drawn; nothing is written outside the output folder
- [x] T028 [US1] Implement the calendar drawings of `SyntheticCases` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticCases.swift` and `SyntheticCalendars.swift` (week, day and month views with hour labels, column headers, coloured blocks at exact times, Outlook-like and dark looks, optional remote-client frame with a title bar, English and Spanish, 12 and 24 hour clocks) with exact `expected.json` and `meta.json` by construction, fixed seeds and a fixed clock
- [x] T029 [US1] Implement the other drawings of `SyntheticCases` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticMessages.swift` (email list and reading pane in Apple Mail-like and plain web looks, Teams-like dark chat, plain document, an empty picture and a text-free picture, the relative-date, "X needs Y" and midnight-in-another-zone cases); the `SyntheticCasesTests` pass
- [x] T030 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvalRunnerTests.swift` with a fake `CaseAnalysing` (scripted results per case): every case is run and scored; `--only` runs one; `replay` re-scores stored step answers without calling the analyser; the report carries the settings, thresholds and `ranWhileAppBusy`; a refusal from `BusyCheck` stops before any case unless `allowBusy` is set; an unreachable server (status from `OllamaService`) stops with the status text and scores nothing; `local` and `synthetic` results are separated
- [x] T031 [US1] Implement `EvalRunner` and the `CaseAnalysing` protocol in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalRunner.swift`; the tests pass
- [x] T032 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvalCommandTests.swift` for the argument parser of `memorri-eval`: `generate-synthetic`, `run` with `--cases`, `--out`, `--size`, `--model`, `--think`, `--prompt-set` (only `v1` exists; an unknown set is a usage error), `--address`, `--only`, `--replay`, `--allow-busy`, `--min-recall`, `--min-precision`, `compare a b`, `sweep-size` with `--sizes`; unknown commands and options give a usage error; a non-local `--address` is rejected like the app does (exit 2); exit codes 0 (finished), 1 (error), 2 (refusal), 3 (below a minimum)
- [x] T033 [US1] Implement the command parser in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalCommand.swift` and the thin front end in `Packages/MemorriCore/Sources/memorri-eval/main.swift` (`generate-synthetic`, `run`, `compare`; `sweep-size` prints `not implemented yet` until User Story 9); the tests pass
- [x] T034 [US1] Generate the synthetic set with `swift run --package-path Packages/MemorriCore memorri-eval generate-synthetic` into `eval/golden/synthetic/`, run it twice and confirm `git status` shows no change the second time, check the folder size (aim under 10 MB in total; reduce picture size in the generator if larger), update `eval/golden/README.md` with the case format, the `origin` rule, the `lines` list and the rule that only `synthetic/` is tracked, and commit the cases
- [x] T035 [US1] Run quickstart Scenario 1 as far as it can run without the real pipeline (generate twice, the busy refusal with a running fake job, replay and compare with an edited expectation using a stored report made by a fake analyser in a test fixture) and fix any difference

**Checkpoint**: User Story 1 works with a fake analyser: the synthetic set exists and is deterministic, scores and comparisons are correct, the busy check refuses.

---

## Phase 4: User Story 2 - Read the text on every capture and keep it with its position (Priority: P1)

**Purpose**: **Goal**: every stored picture is read in the background and its lines are kept with exact boxes; an `analyse` job exists and does the read step.

- [x] T036 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReadingOrderTests.swift` and `VisionGeometryTests.swift`: `ReadingOrder.sort` gives the same numbers for the same lines in any input order; two lines on one row sort left to right; rows are grouped with half the median line height as tolerance; numbers start at 1; Vision's normalised bottom-left box converts to integer top-left pixels of the picture for a few known boxes and for a picture size that is not square
- [x] T037 [US2] Implement `RecognisedLine`, `TextRecogniser`, `ReadingOrder` and `VisionTextRecogniser` (`RecognizeTextRequest`, accurate, language correction as decided by T006, automatic language detection, `descriptor` string for `ocr_reads.recogniser`) in `Packages/MemorriCore/Sources/MemorriCore/Recognition/TextRecogniser.swift`; the tests pass
- [x] T038 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OCRStoreTests.swift`: saving lines stores text, box and confidence under `(image_id, n)`; saving twice leaves one set; zero lines stores an `ocr_reads` row with `line_count` 0 and `isRead` is true; lines come back in order; deleting the capture removes them
- [x] T039 [US2] Implement `OCRStore` in `Packages/MemorriCore/Sources/MemorriCore/Recognition/OCRStore.swift`; the tests pass
- [x] T040 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StoredPictureProviderTests.swift` (extend): `fullPicture(imageID:)` decodes the stored full-resolution HEIC to a `CGImage` of the recorded pixel size and returns nil for a missing row or file
- [x] T041 [US2] Implement `FullPictureProviding` and `StoredPictureProvider.fullPicture(imageID:)` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/StoredPictureProvider.swift`; the tests pass
- [x] T042 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ImageAnalysisJobTests.swift` (read step only, using `makePipelineFixture`, `FakeTextRecogniser`): an `analyse` job reads the picture's full-resolution copy and stores its lines; a second run of the same job does not call the recogniser again (`ocr_reads` exists); a picture with no text succeeds with zero lines; a missing picture gives `permanent("picture no longer stored")` and writes nothing; a recogniser error is `transient("text recognition failed")`; the job logs `read image=<id> lines=<n> ms=<n>` in category `extraction` and logs no text
- [x] T043 [US2] Implement `ImageAnalysisJobRunner` (kinds `analyse` and `analyse-force`, step list with only the read step for now; it gains its dependencies (classification, results, contexts) story by story, so its initialiser grows as the phases proceed) in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift`; the tests pass
- [x] T044 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/PictureIngestTests.swift`: `PictureIngest.store(png:windows:)` decodes a PNG, writes the full and analysis HEIC copies through `CaptureFileStore`, inserts one event (trigger `menu`) and one image row with the right sizes, stores the optional windows, returns the image id, and a file that is not a picture gives an error and writes nothing
- [x] T045 [US2] Implement `PictureIngest` in `Packages/MemorriCore/Sources/MemorriCore/Capture/PictureIngest.swift` (shared by the debug switch; also usable by tests and eval), and `App/DebugIngest.swift` handling `--ingest-picture <png>` and `--ingest-windows <json>` at launch in Debug builds only (compiled out of Release), which stores the picture and enqueues one `analyse` job; the tests pass
- [x] T046 [US2] Wire in `App/AppEnvironment.swift`: create `VisionTextRecogniser`, `OCRStore` and the `ImageAnalysisJobRunner`, register it under `analyse` and `analyse-force` in a `CompositeJobRunner` that also holds the `test` runner, and give the queue that runner; Spec 003 behaviour is unchanged
- [x] T047 [US2] Run quickstart Scenario 2 (read part) in an isolated home: ingest a synthetic week-view picture with the debug switch, check `ocr_lines` against the case's expected `lines` (at least 95% exact, SC-003), ingest the text-free picture (zero lines, finished), reanalyse to show no duplicate lines, delete all captures and check the tables are empty; fix any difference

**Checkpoint**: User Story 2 works on its own: a synthetic picture ingested through the debug switch is read and its lines match the drawn text.

---

## Phase 5: User Story 4 - Use the right questions for each kind of screen (Priority: P1)

**Purpose**: **Goal**: each read picture is classified as one of seven kinds; an unsure answer is `other`. The classification is kept as a model run so a retry does not repeat the call. (Story numbers follow the spec: US4 is classification, US3 is extraction, built in Phase 6 because it needs the kind.)

- [ ] T048 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ClassificationTests.swift`: `ScreenKind` has the seven raw values and `init?(rawValue:)` rejects others; `ExtractionSchemas.classifySchema` accepts a known-good answer (`screen_kind`, `kind_confidence`, `application`, `platform_look`, `remote_session` with `is_remote` and `client`, `theme`, `calendar_name`) and rejects a missing `screen_kind`, an unknown kind and a non-numeric confidence; the classify prompt lists all seven kinds and asks for the application, platform look, remote session, theme and calendar name; `ClassificationResult.resolved(threshold:)` maps a confidence below the threshold from T006 (0.5 unless the spike says otherwise) to `other`
- [ ] T049 [US4] Add the classify schema (`ScreenKind` already exists from the golden case task) and prompt with version `classify-v1` (`Packages/MemorriCore/Sources/MemorriCore/Extraction/Schemas.swift`, `Packages/MemorriCore/Sources/MemorriCore/Extraction/Prompts.swift`) and `ClassificationResult`; the tests pass
- [ ] T050 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift` (classification slice, fakes): a run reads the picture, calls the model once for classification with the JPEG copy first, and returns the kind and the visual tag values; an unsure answer becomes `other`; an answer that fails the schema throws `transient("invalid answer")`; an unreachable server throws `serverUnavailable`; a run resumed with stored lines and a stored classification makes no recogniser call and no model call; the `classify` step record has the raw answer and the request without picture data
- [ ] T051 [US4] Implement the read and classify steps of `AnalysisPipeline` (`PipelineInput`, `PipelineError`, `StepRecord`, `AnalysisResult` with no findings yet) in `Packages/MemorriCore/Sources/MemorriCore/Extraction/AnalysisPipeline.swift` using `ModelStep`; the tests pass
- [ ] T052 [US4] Extend `Packages/MemorriCore/Tests/MemorriCoreTests/ImageAnalysisJobTests.swift` and `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift`: the runner calls the pipeline, writes a `model_runs` row with `step = classify` for the call (success or failure, raw answer kept), finds a stored successful classify run for the current `classify-v1` and passes it as `reuse`, maps `PipelineError` to `JobOutcome` as in spec 003, and logs `classify image=<id> kind=<kind> confidence=<x> ms=<n>`; tests first, then the change
- [ ] T053 [US4] Run the classification part of quickstart Scenario 2: ingest one synthetic picture of each of the seven kinds with the real model, read `model_runs` (`step = classify`) and confirm the kinds; note the accuracy and the seconds per call in `spike-report.md`; fix any difference

**Checkpoint**: User Story 4 works: each synthetic kind is classified by the real model and the answer is stored.

---

## Phase 6: User Story 3 - Find appointments, tasks and deadlines in a capture (Priority: P1)

**Purpose**: **Goal**: each read and classified picture gets findings with cited lines, stored per picture; captures are analysed automatically; Settings lists recent captures with their findings; the eval tool runs the real pipeline. Dates stay as written (flagged unresolved) until Phase 7 and missing ends stay empty until Phase 8.

- [ ] T054 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/FindingsTests.swift`: `FindingDraft` parses every optional field and rejects an unknown kind or a draft without `cited_lines`; `CitationCheck.apply` keeps drafts citing at least one existing line, discards drafts citing none or a line outside `1...lineCount`, and returns a discard record with title, reason and the cited numbers; finding confidence is the lowest cited-line confidence and at most 0.5 when any field is inferred; provenance is kept for start, end, due, remind and all-day, and title, people, place and notes carry none (always read)
- [ ] T055 [US3] Implement `FindingKind`, `FieldOrigin`, `FieldProvenance`, `FindingDraft`, `Finding` and `CitationCheck` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/Findings.swift`; the tests pass
- [ ] T056 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/PromptsSchemasTests.swift`: every kind has a prompt version `extract-<kind>-v1` and a schema version `schema-<kind>-v1`; each extract schema accepts a known-good answer and rejects a finding without `cited_lines`, with an empty title or with an unknown `kind`; week and day schemas allow `column_line`, email allows `sent_text`, chat allows `message_time_text`; the prompt says to use only what is on screen, to cite the lines that show each fact, to copy dates and times as written and that "X needs Y" is a task for X; lines are written as `L<n> (x%,y%) text`; more than 600 lines are capped (smallest boxes dropped first) and `capApplied` is true
- [ ] T057 [US3] Implement the extraction prompts and schemas per kind in `Packages/MemorriCore/Sources/MemorriCore/Extraction/Prompts.swift` and `Packages/MemorriCore/Sources/MemorriCore/Extraction/Schemas.swift` (seven kinds, `other` uses the general prompt, line list formatting and cap per R4, message order from T006); the tests pass
- [ ] T058 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisResultStoreTests.swift`: `save` writes `image_analysis`, findings, tags and the context row in one transaction and a failure half-way leaves nothing; saving again for the same picture replaces findings, tags and the analysis row and keeps the earlier `model_runs`; an `image_context` row with `source = user` survives a save; findings round-trip their provenance, unresolved texts, cited lines and tags copy; discards are stored; `unanalysedImageIDs` excludes analysed pictures and pictures with a waiting or running job and is oldest first; deleting a capture removes everything that belongs to it
- [ ] T059 [US3] Implement `AnalysisResultStore` and `StoredAnalysis` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisResultStore.swift`; the tests pass
- [ ] T060 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift` (extraction slice): after classification the model is called once more with the prompt and schema of the kind and the numbered lines; findings come back with their cited lines; a finding with a bad citation is discarded and recorded while the others stay; an empty list gives an analysed result with zero findings; an answer that fails the schema throws `transient`; a task phrased "Anna needs the report by Friday" arrives as a task with people `[Anna]`; dates are kept as written and listed in `unresolved` (the resolver is a placeholder until Phase 7); the extract step is repeated on retry while read and classify are reused
- [ ] T061 [US3] Implement the extract step and result assembly in `AnalysisPipeline` (`DateResolver.resolve` as a placeholder returning the text as written with rule `unresolved`), extend `ImageAnalysisJobRunner` to write the `extract` run, save the result with `AnalysisResultStore` and log `extract image=<id> kind=<kind> findings=<n> discarded=<n> ms=<n>`, `resolve image=<id> unresolved=<n> inferred=<n>` and `analysis stored image=<id>`; the tests pass
- [ ] T062 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisSettingsTests.swift` and extend `CapturePipelineTests.swift`: `AnalysisSettings.automatic` defaults to true and round-trips under `memorri.analysis.auto`; after a successful capture `CapturePipeline` calls the enqueuer once with the stored picture ids (one per display) when the switch is on, and never when it is off, for a failed capture or when the store failed; a failing enqueuer does not fail the capture
- [ ] T063 [US3] Implement `AnalysisSettings` in `Packages/MemorriCore/Sources/MemorriCore/Settings/AnalysisSettings.swift` and the optional enqueuer in `Packages/MemorriCore/Sources/MemorriCore/Capture/CapturePipeline.swift`; the tests pass
- [ ] T064 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisQueueTests.swift` (extend): `enqueueBacklog()` adds one `analyse` job per unanalysed picture, oldest first, and a second call adds none; `reanalyse(imageID:)` adds an `analyse-force` job and a picture already waiting is not queued twice; both log `enqueued analyse=<n> reason=<capture|backlog|reanalyse>`
- [ ] T065 [US3] Implement `enqueueBacklog()` and `reanalyse(imageID:)` on `AnalysisQueue` using `AnalysisResultStore.unanalysedImageIDs`; the tests pass
- [ ] T066 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/RecentCapturesTests.swift`: `CaptureOverview.recent(limit:)` returns the newest 20 pictures with capture time, display count, state (`Waiting`, `Analysing`, `Analysed`, `Failed(reason)`, `NotAnalysed`) derived from the analysis row and the job, screen kind, finding count and the findings for the disclosure; a picture with a failed job shows the job's reason; a capture with three displays returns three rows
- [ ] T067 [US3] Implement `CaptureOverview` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/CaptureOverview.swift`; the tests pass
- [ ] T068 [US3] Wire in `App/AppEnvironment.swift`: create `AnalysisPipeline`, `AnalysisResultStore`, `AnalysisSettings` and `CaptureOverview`, pass the queue as the enqueuer of `CapturePipeline`, expose `analyseStoredCaptures()`, `reanalyse(imageID:)` and the automatic switch, and start nothing new when the storage is unavailable
- [ ] T069 [US3] Create `App/Windows/AnalysisSettingsView.swift` and add the Analysis row to `App/Windows/SettingsView.swift` per `contracts/ui-contract.md`: the `Analyse new captures automatically` switch with its note, **Analyse stored captures** with the count note, and the list of the 20 most recent pictures with time, displays, state, kind, finding count, the `Findings` disclosure (`<kind> · <title> · <date as written or resolved>`) and **Reanalyse**; refresh on queue progress; the view never logs text
- [ ] T070 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/PipelineCaseAnalyserTests.swift`: `PipelineCaseAnalyser` (the real `CaseAnalysing`) builds a `PipelineInput` from a golden case: the full picture, an analysis copy at `--size` made with the app's encoder and converted to JPEG like the queue does, the case's capture time, windows, context and zones from `meta.json`, and returns findings, kind, tags and the step records for the report; a fake model and recogniser are used
- [ ] T071 [US3] Implement `PipelineCaseAnalyser` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/PipelineCaseAnalyser.swift` and connect `memorri-eval run` to it (server status check first, `--model`, `--think`, `--size`, `--address`); the tests pass
- [ ] T072 [US3] Run quickstart Scenario 3 (findings part) and the first real eval: ingest the email and week cases, check findings and citations with `sqlite3` (`select count(*) from findings where cited_lines_json = '[]'` is 0, SC-004), run the fake `extract-bad-citation` and `extract-empty` modes, then pause the app and run `memorri-eval run` on the synthetic set; record the first scores (dates unresolved, ends empty) in `quickstart.md`; fix any difference

**Checkpoint**: User Story 3 works: new captures are analysed, findings are stored with valid citations, and `memorri-eval run` scores the real pipeline on the synthetic set.

---

## Phase 7: User Story 5 - Get real dates and times, not "tomorrow" (Priority: P2)

**Purpose**: **Goal**: literal dates become full dates in the right zone with the rule recorded; anything unresolvable stays as written and flagged.

- [ ] T073 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/DateParserTests.swift`, table driven with at least 40 cases: English and Spanish month and weekday names and abbreviations, ordinal suffixes, numeric dates in day-month, month-day and year-first order, 12-hour with am/pm and 24-hour times, `tomorrow`, `mañana`, `today`, `in 2 days`, `next Monday`, `el próximo lunes`, `end of week`, `fin de semana` edge, a time only, a weekday only, and text that is not a date giving nil; `dateOrder(ofUnambiguous:)` from dates such as `14/10` and `10/14`
- [ ] T074 [US5] Implement `DateParser` and `DateOrder` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/DateParser.swift` (names from `Calendar` and `DateFormatter` symbols of the locales tried, English and Spanish first); the tests pass
- [ ] T075 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/DateResolverTests.swift`, table driven with at least 40 cases: each rule (`explicit-date`, `header-column`, `relative-day`, `end-of-week`, `weekday-only`, `time-only`, `deadline-reminder`, `unresolved`) with its rule id in the provenance; week-view header columns chosen by the nearest horizontal centre; a year rollover in December; a capture at 00:10 in a zone whose date differs from the Mac's (`today` and `tomorrow` use the context's date); the email's `sent_text` as the reference; an ambiguous numeric order taking the order of unambiguous dates in the picture and marked inferred with reason `date-order`; an all-day value; a deadline with an action and no reminder text gets `remind` at 09:00 local on the working day before the due date (a Monday due date gets the previous Friday) with origin `inferred` and rule `deadline-reminder`, a deadline with literal reminder text uses it as read and a date-only item gets none; a value that cannot be resolved kept as written in `unresolved` with the field left empty
- [ ] T076 [US5] Implement `DateResolver`, `DateHeader`, `ResolutionContext` and `ResolvedValue` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/DateResolver.swift` replacing the placeholder; the tests pass
- [ ] T077 [US5] Extend `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift` and `AnalysisPipeline.swift`: headers are found in the lines with `DateResolver.headers`, each finding's texts are resolved with its `column_line` or first cited line, `start`, `end`, `due` and `remind` get provenance with the rule, unresolved texts are kept, the time zone is the Mac's (the context arrives in Phase 9) and `image_analysis.timezone_source` says `mac`; tests first, then the change
- [ ] T078 [US5] Run quickstart Scenario 3 (dates part): run the eval on the synthetic date cases, list any case whose date is wrong with the rule that produced it, fix the rule or the drawing, and record the date-case results (SC-005 asks for all of them; if a case cannot be resolved by the rules, amend the spec with the evidence instead of weakening the case)

**Checkpoint**: User Story 5 works: date cases in the synthetic set resolve to the expected dates and zones.

---

## Phase 8: User Story 6 - Fill in missing end times sensibly and say so (Priority: P2)

**Purpose**: **Goal**: an appointment without an end gets one from its block's height, else one hour, flagged inferred with the reason.

- [ ] T079 [P] [US6] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/BlockGeometryTests.swift` using drawn pictures: `hourScale` fits labels such as `9 AM` to `5 PM` and `09:00` to `17:00` and returns nil with fewer than two labels or labels not in one narrow column; `blockHeight` returns the coloured block's height for solid, outlined, rounded-corner, overlapping and dark styles (styles the spike report says work) and nil for a region wider than a column or equal to the page background; `duration` rounds to 15 minutes and limits to 30 to 720; a title line with no block around it gives nil
- [ ] T080 [US6] Implement `HourScale` and `BlockGeometry` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/BlockGeometry.swift` as designed in research R7 and corrected by T006; the tests pass
- [ ] T081 [US6] Extend `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift`: in `calendar_week` and `calendar_day` pictures an appointment with a start and no end gets an end from the block height with provenance `inferred` and reason `block-height`; with no geometry or another kind it gets start plus 60 minutes with reason `default-60`; an explicit end is used as `read` with no inferred flag; an end that would pass midnight is cut at the end of the day and flagged inferred; tasks and deadlines get no end
- [ ] T082 [US6] Implement the duration step in `AnalysisPipeline` (column width from the median spacing of the header lines, else picture width over 7 for a week and the picture width for a day), using the full picture from `PipelineInput`; the tests pass
- [ ] T083 [US6] Run quickstart Scenario 3 (duration part): ingest the week case with 90-minute and 30-minute blocks and a text-only meeting, check the ends and `provenance_json`, run the eval and check that every guessed end is flagged inferred with its reason and no read value is flagged (SC-006); fix any difference

**Checkpoint**: User Story 6 works: block heights and defaults give the expected ends and the flags are right.

---

## Phase 9: User Story 7 - Know which customer or session a capture came from (Priority: P2)

**Purpose**: **Goal**: window titles are recorded at capture; contexts with hints and zones exist; each picture is assigned automatically with the reasons recorded; the user's choice is final; the context's time zone drives date resolution.

- [ ] T084 [P] [US7] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ContextStoreTests.swift`: `add` stores name, optional IANA zone and hints; a name already used (ignoring case) is rejected; an invalid zone identifier is rejected; a hint shorter than 2 characters is rejected; `update` changes name, zone and hints; `delete` removes the context and its hints and leaves pictures with `context_id` null and their findings intact; `setUserChoice` writes `source = user` and `decision(imageID:)` reads it back
- [ ] T085 [US7] Implement `ContextRecord`, `ContextHint` and `ContextStore` in `Packages/MemorriCore/Sources/MemorriCore/Contexts/ContextStore.swift`; the tests pass
- [ ] T086 [P] [US7] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ContextMatcherTests.swift`, table driven: a window-title hint (3 points), an application hint (3), a domain hint matched against tag values or lines (2.5), a keyword in the lines (1); case-insensitive; a hint counts once however many times it appears; at least 2 points and a lead of at least 1 are needed; two equal scores give `none` with both contexts recorded as a tie; the matched hints and the runner-up are in the decision; no contexts or no match gives `none`; `domain` and `keyword` hints are never matched against window titles of other kinds incorrectly (only their own sources)
- [ ] T087 [US7] Implement `ContextMatcher`, `ContextDecision`, `MatchedHint` and `RunnerUp` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/ContextMatcher.swift`; the tests pass
- [ ] T088 [US7] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowCaptureTests.swift` and extend `CapturePipelineTests.swift`: `CapturePipeline` stores each display's windows with its picture in the same transaction, keeping at most 20 per display, largest visible area first, frames clipped to the picture; a failing insert leaves no windows; the titles are never logged
- [ ] T089 [US7] Implement the window selection (largest first, at most 20, clipping) and the storing in `Packages/MemorriCore/Sources/MemorriCore/Capture/CapturePipeline.swift`; the tests pass
- [ ] T090 [US7] Update `App/Adapters/ScreenCaptureKitCapturer.swift` to fill `windows` from the `SCShareableContent` it already fetches (on-screen windows at layer 0 whose frame intersects the display, largest visible area first, at most 20, application name, bundle id and title, frame converted to the picture's pixel space) as decided in T006; measure the added milliseconds with the capture log line and confirm a capture on this Mac stores windows (count only, never read titles)
- [ ] T091 [US7] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift` and `ImageAnalysisJobTests.swift` (extend): the pipeline gets the contexts and windows, picks a context with `ContextMatcher`, uses its zone to resolve dates (a capture at 23:40 UTC with a New York context resolves `tomorrow` on the New York date) and records `timezone_source` `context`; an invalid context zone falls back to the Mac's with `invalid-context-zone`; no match uses the Mac's zone; a user choice wins over the matcher and is kept by `analyse-force`; the decision is stored in `image_context` and logged as `context image=<id> source=<auto|user|none> name=<name|->`
- [ ] T092 [US7] Implement the context step in `AnalysisPipeline` and `ImageAnalysisJobRunner` (load contexts and the picture's windows, the stored user choice, save the decision); the tests pass
- [ ] T093 [US7] Extend `App/Windows/AnalysisSettingsView.swift` per `contracts/ui-contract.md`: the context of each recent picture with `(chosen by you)` and a picker (`Unassigned` plus every context) that calls `ContextStore.setUserChoice`, and the Contexts block (add, rename, time zone picker with `Mac's time zone` first, hints with kind picker and value, remove, delete) with the messages `That name is already used.` and `Enter at least 2 characters.`; all logic stays in `ContextStore`
- [ ] T094 [US7] Run quickstart Scenario 4 (contexts part) in an isolated home: insert two contexts with `sqlite3`, ingest pictures with `--ingest-windows`, check assignments, the tie case, the zone effect on a date, the user choice through the picker (AX can click pickers but cannot type; ask the user to try adding a context and a hint by typing) and that `analyse-force` keeps it, and that deleting a context leaves findings; fix any difference (SC-007)

**Checkpoint**: User Story 7 works: pictures are assigned to the right context, a user override survives reanalysis and the context zone changes resolved dates.

---

## Phase 10: User Story 8 - Tag each capture with what its environment looks like (Priority: P2)

**Purpose**: **Goal**: every analysed picture has environment tags with value, confidence and source; findings copy them; tags feed context matching and date reading; the eval scores them.

- [ ] T095 [P] [US8] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/TagExtractorTests.swift`, table driven: `fromCapture` gives `display_size`, `display_scale`, `window_app`, `window_title_keywords` and `remote_client` for owning applications in the known remote-client list (Citrix Viewer, Microsoft Remote Desktop, Windows App, VMware Horizon, Parallels, Jump Desktop) and none for browsers, Teams or Mail; `fromLines` gives `language` (English and Spanish text), `clock_style` (12h, 24h, mixed gives the more frequent), `date_order` from unambiguous dates, `account` and `domain` from email addresses with `line:<n>` sources, `timezone_label` for `GMT+2`, `CEST`, `UTC-5`; `fromClassification` marks visual tags below 0.6 as low and stores nothing for unknown; no tag carries a value the picture does not show
- [ ] T096 [US8] Implement `CaptureTag` and `TagExtractor` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/TagExtractor.swift`; the tests pass
- [ ] T097 [US8] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisPipelineTests.swift`, `AnalysisResultStoreTests.swift` and `ContextMatcherTests.swift` (extend): the pipeline assembles tags from the capture, the lines and the classification; every finding's `tags_json` equals the picture's tags of that run; reanalysis replaces the tags; a context with a `domain` hint matches through an `account` or `domain` tag and through a `remote_client` tag; `DateResolver` uses the `date_order` and `clock_style` tags when the picture's own dates do not settle them
- [ ] T098 [US8] Implement the tag assembly in `AnalysisPipeline`, the `capture_tags` writes and `Finding.tags` in `AnalysisResultStore`, and the tag inputs of `ContextMatcher` and `DateResolver`; the tests pass
- [ ] T099 [US8] Extend `App/Windows/AnalysisSettingsView.swift` per `contracts/ui-contract.md`: the tags of each picture as small labels (application, platform look, remote client, clock style, language, theme); account and domain values appear only inside the picture's `Findings` disclosure, not in the list row
- [ ] T100 [US8] Run quickstart Scenario 4 (tags part): run the eval on the synthetic set, read tag accuracy per key and the count of wrong high-confidence tags (SC-012: application, platform look and clock style at least 90% where shown; wrong with high confidence at most once in 20 cases), check `tags_json` equals the picture's tags for every finding, and fix or amend with evidence

**Checkpoint**: User Story 8 works: tags are stored as drawn, findings carry them and eval reports tag accuracy per key.

---

## Phase 11: User Story 9 - Choose the picture size from evidence (Priority: P3)

**Purpose**: **Goal**: a measured default for the analysis picture size, recorded in an ADR.

- [ ] T101 [P] [US9] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SizeSweepTests.swift` with a fake `CaseAnalysing` that returns different scores per size: the sweep runs every size on every case, prints precision, recall, field accuracy and mean seconds per size; the recommendation is the smallest size whose findings F1 and field accuracy are each within 0.02 of the best, and stays 2048 when no smaller size qualifies; ties prefer the smaller size
- [ ] T102 [US9] Implement `sweep-size` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalRunner.swift` and the command in `Packages/MemorriCore/Sources/memorri-eval/main.swift` (sizes default to 1024, 1536, 2048, 3072); the tests pass
- [ ] T103 [US9] Run `memorri-eval sweep-size` with the app paused on the synthetic set (and any local cases the user has), write the table and the recommendation into `spike-report.md`, and write ADR `docs/architecture/decisions/0017-analysis-picture-size-default.md` (status Accepted) with the numbers and the decision
- [ ] T104 [US9] If the recommendation differs from 2048, write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageSettingsTests.swift`: the default `modelLongEdge` is the new value when the user never set one, and a stored user value is kept; otherwise record that the default stays and skip this task and the next
- [ ] T105 [US9] Change the default in `Packages/MemorriCore/Sources/MemorriCore/Settings/StorageSettings.swift` (only if T104 applies) and check Settings → Storage shows it; the tests pass

**Checkpoint**: User Story 9 works: the sweep report exists, the ADR records the decision and the setting behaves as stated.

---

## Phase 12: Polish and cross-cutting concerns

**Purpose**: Documents, full verification, a fresh clone and the pull request. The polish tasks that edit different files can run in parallel.

- [ ] T106 [P] Update the design documents to match what was built (including the files added beyond the plan: `SyntheticCalendars.swift`, `SyntheticMessages.swift`, `PictureIngest.swift`, `CaptureOverview.swift`, `PipelineCaseAnalyser.swift`, `EvalCommand.swift`, `WindowInfo.swift`, `PixelBox.swift`, `ModelStep.swift`): `contracts/core-interfaces.md`, `contracts/eval-cli.md`, `contracts/ui-contract.md`, `plan.md`, `data-model.md` and `research.md` for any deviation; set ADRs 0014, 0015 and 0016 in `docs/architecture/decisions/` from `Proposed` to `Accepted` (0017 is written Accepted by T103)
- [ ] T107 [P] Update `CLAUDE.md` and `DEVELOPER.md`: the tool is `Packages/MemorriCore/Sources/memorri-eval` (not `Tools/memorri-eval`); add how to run `memorri-eval` (`generate-synthetic`, `run`, `compare`, `sweep-size`, the busy refusal and `--allow-busy`), the golden case format and the rule that only `eval/golden/synthetic/` is tracked, the debug `--ingest-picture` and `--ingest-windows` switches, the `extract` modes of `scripts/fake-ollama.py`, the `extraction` log category and its lines, contexts and tags in Settings → Analysis, and rewrite section 8 ("Change a prompt, schema or model") with the real commands; update the status line in `README.md` (the app now reads captures and finds appointments and tasks, not yet synced anywhere)
- [ ] T108 Run `swift test --package-path Packages/MemorriCore` and a clean `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode clean build`; both must pass with no warnings from our code; run `lsof -i -a -p $(pgrep -x Memorri)` during an analysis and again for `memorri-eval` during a run and confirm connections only to localhost; confirm with `grep -rn URLSession App Packages/MemorriCore/Sources` that only `OllamaURLSessionTransport.swift` uses it; confirm the SC-001 and SC-002 targets on the synthetic set with the final pipeline (findings precision and recall at least 0.85, field accuracy at least 0.90, classification at least 90%; if a target is missed, amend the spec with the measured evidence and the reason rather than weakening the set); confirm `git ls-files eval` lists only `README.md` and `synthetic/` files and that no real picture, capture or model answer is tracked; build the app in Release (`xcodebuild -configuration Release`) and confirm the debug ingest switches are absent (`strings` on the binary finds no `--ingest-picture`)
- [ ] T109 Run quickstart Scenario 5 (automatic analysis and the queue) with a prepared test screen: capture with the hotkey and watch one job per display finish in under 3 minutes with the menu and Settings responsive (SC-008), turn the switch off and capture again (no job), **Analyse stored captures** twice (second adds none), pause and relaunch, kill the app during the extract step and confirm the job resumes without repeating the read; fix any difference
- [ ] T110 Validate a fresh clone: clone the repository into a temporary directory on this branch, follow only `DEVELOPER.md` to build and test, run `memorri-eval generate-synthetic` and confirm it produces no change, and confirm everything passes; commit `Package.resolved` if the build changes it; time it
- [ ] T111 Set the status of 004 to `Done` in `docs/roadmap.md`, fill the observed results (spike numbers, eval scores on the synthetic set, scenario outcomes, noting which success criteria were observed by hand and which targets were amended with evidence) into `specs/004-ocr-extraction-and-eval/quickstart.md`, and prepare the pull request description with the Definition of done checklist from `DEVELOPER.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup and spikes)**: T001 first (it draws the pictures the others reuse); T002, T003 and T005 are independent of each other; T004 needs T001 and the running server; T006 needs all four. Start the long runs (T004) in the background and continue with Phase 2.
- **Phase 2 (Foundational)**: after T001 for the facts it sets; blocks every story. Test and implementation pairs go pair by pair; T016 edits `Fakes.swift`, so it is not parallel with other tasks that edit it.
- **US1 (Phase 3)**: after Foundational. MVP: the harness works against a fake analyser.
- **US2 (Phase 4)**: after Foundational; independent of US1 except the ingest helper is reused by the eval later.
- **US4 (Phase 5)**: after US2 (needs the lines) and T006 (the threshold).
- **US3 (Phase 6)**: after US4 (needs the kind) and US1 (the eval runs the real pipeline at its end).
- **US5 (Phase 7)**: after US3. **US6 (Phase 8)**: after US5 (same pipeline step and the start times).
- **US7 (Phase 9)**: after US3; the zone use needs US5. Window capture (T088 to T090) can start after Foundational (the types are built there, T010).
- **US8 (Phase 10)**: after US7 (tags feed the matcher) and US5.
- **US9 (Phase 11)**: after US3 and preferably after US5 to US8 so the sweep measures the finished pipeline.
- **Polish (Phase 12)**: after all stories.

### Within Each User Story

- Tests first and failing, then the core type, then wiring, then the view, then the quickstart scenario.
- `AnalysisPipeline.swift` and `ImageAnalysisJob.swift` are edited by US4, US3, US5, US6, US7 and US8 in that order; `AnalysisSettingsView.swift` by US3, US7 and US8.

### Parallel Opportunities

- Phase 1: T002, T003 and T005 together after T001.
- Phase 3: the test tasks for `GoldenCase`, `Matcher`, `Metrics`, `EvalReport` and `BusyCheck` are in distinct files.
- Phase 4: T036, T038, T040 and T044.
- Phase 6: T054, T056, T058 and T066.
- Phase 7 and 8: T073 with T075; T079 can start during Phase 7.
- Phase 9: T084, T086 and T088.
- Phase 12: T106 and T107.

---

## Parallel Example: US1 tests

```bash
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/GoldenCaseTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/MatcherTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/MetricsTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/BusyCheckTests.swift"
```

---

## Implementation Strategy

### MVP (Phases 1 to 3)

The spikes, the foundation and the eval harness with its synthetic set. At that point there is a way to measure, and nothing in the app has changed yet.

### First useful app (add Phases 4 to 6)

Every new capture is read, classified and mined for findings with cited lines, visible in Settings → Analysis, and `memorri-eval run` scores the real pipeline. Dates stay as written and ends stay empty, which the spec allows.

### Accuracy (add Phases 7 to 10)

Real dates and zones, sensible ends, contexts and tags. Each phase ends with an eval run, so a change that lowers a score is seen at once (Constitution VI).

### Last (Phases 11 and 12)

The picture size study and the polish. The pull request is opened only when the user asks.

### Notes

- Commit after each task or pair of tasks, with the `Co-Authored-By: Claude <model> <noreply@anthropic.com>` line.
- Tick each task in this file when it is done.
- After any change to a prompt, a schema or a rule, run `memorri-eval run` on the synthetic set with the app paused and keep the report in `eval/out/` (ignored).
