---

description: "Task list for spec 011: window-aware analysis"
---

# Tasks: Read each window on its own, so dates come from the window that shows them

**Input**: Design documents from `/specs/011-window-aware-analysis/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md. This branch starts from spec 006's branch (it needs the date-reading fix, the guess flag and the evidence geometry that shipped there).

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first and any prompt, schema or model change to pass the eval: write the test, see it fail, then implement; run the eval for every prompt change. App views are proven by the quickstart.

**Organization**: Grouped by user story in priority order: US1 several windows (P1), US2 another month (P1), US3 reference clock (P2), US5 library re-read and cost (P2), US4 window names and cut-outs (P3). Paths follow plan.md; core is `Packages/MemorriCore/Sources/MemorriCore` and tests are `Packages/MemorriCore/Tests/MemorriCoreTests`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US5 as in the spec
- Commands assume the repository root as the working directory.
- **Privacy**: tests and eval use synthetic titles and drawn pictures only. Real captures and the user's real database are opened only where a task says so and only with the user's go-ahead and their copy of the app closed; nothing from them (titles, names, window titles, screen text) is printed, stored in git or written in docs. Run the app for checks with `CFFIXED_USER_HOME` set to a scratch folder, screenshots by window id only, buttons through accessibility (never by screen position), and delete scratch data afterwards.
- Tasks that edit `Tests/MemorriCoreTests/Fakes.swift` are not marked parallel.
- Phase 6 (US5) needs the pipeline of Phase 3; Phase 7 (US4) needs Phase 2's window key and Phase 3's readings.

## Phase 1: Setup

**Purpose**: Migration v8 and the job priority every story needs.

- [X] T001 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v8"` per `data-model.md`: table `window_readings` with columns `image_id` (not null, references `capture_images(id)` ON DELETE CASCADE), `window_key` (not null), `app_name` (null), `title` (null), `frame_json` (not null), `visible_json` (not null), `visible_share` (double, not null), `relevant` (integer, not null), `kind` (null), `confidence` (double, not null), `remote` (integer, not null, default 0), `run_id` (null), `prompt_version` (not null), `created_at` (not null) and primary key `(image_id, window_key)`; `findings` gains `window_key` (text, null); `image_analysis` gains `reference_at` (datetime, null), `reference_source` (text, null) and `windows_read` (integer, not null, default 1); `sightings` and `evidence` gain `window_app` and `window_title` (text, null); `analysis_jobs` gains `priority` (integer, not null, default 0) and the index `(state, priority, created_at)` replaces `analysis_jobs_state_created_at`; deleting a capture image removes its `window_readings`; a v7 database migrates with its rows intact and old findings have `window_key` null
- [X] T002 Implement migration `"v8"` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift` per `data-model.md`; the previous task's tests pass
- [X] T003 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisStoreTests.swift` (extend it; the job store tests live there): `nextRunnable` orders by `priority`, `created_at`, `id`; a job enqueued with priority 1 never runs before a waiting priority 0 job whatever its age; `AnalysisJobRecord` round-trips `priority`; a waiting `reread` job for an image makes `hasPendingAnalysis(imageID:)` true and a finished one does not
- [X] T004 Add `priority` to `AnalysisJobRecord` and order `nextRunnable` by it in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisJobStore.swift`; the previous task's tests pass

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 2: Foundational

**Purpose**: The window model, its storage and the window key on findings; blocks every story.

- [ ] T005 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/VisibleScreenTests.swift` for `VisibleScreen.split(lines:windows:pictureWidth:pictureHeight:)` per `research.md` R1 and `contracts/core-interfaces.md`: the visible region of a window is its frame minus the frames in front (stack 0 is the front); a line belongs to the window whose visible region holds its centre, lines in no window are `desktopLines`; windows with under 2% visible area or fewer than 3 lines are dropped; windows of the app itself and of the system UI (Dock, Window Server, Control Centre, by bundle id) are dropped; no stack, one window or no windows gives one window with key `all` covering the picture; keys are `w<stack index>`; line numbers are kept; frames are clipped to the picture Also test the edge case "a dialog or menu is drawn over a calendar": a system-UI window or menu in front is dropped from the list of windows only after the visibility step, so it still hides the calendar's covered part and none of its lines land in the calendar.
- [ ] T006 Implement `VisibleWindow` and `VisibleScreen` in `Packages/MemorriCore/Sources/MemorriCore/Windows/VisibleWindows.swift` and make `SubjectRegion.visibleLines` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/SubjectRegion.swift` use it (its tests keep passing); the previous task's tests pass
- [ ] T007 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowReadingStoreTests.swift`: `WindowReadingStore.save(imageID:readings:)` replaces all rows of a picture, `readings(imageID:)` returns them in key order, rows go with their capture image, `prompt_version` and `run_id` are kept
- [ ] T008 Implement `WindowReadingRecord` and `WindowReadingStore` in `Packages/MemorriCore/Sources/MemorriCore/Windows/WindowReadingStore.swift` and `Packages/MemorriCore/Sources/MemorriCore/Windows/WindowReading.swift`; the previous task's tests pass
- [ ] T009 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisResultStoreTests.swift` (extend): a `Finding` has `windowKey` (nil by default), `AnalysisResultStore.save` writes `findings.window_key`, reads it back, and replaces it on a second save of the same picture; findings saved without a key read back nil
- [ ] T010 Add `windowKey` to `Finding` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/Findings.swift` and to `AnalysisResultStore` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisResultStore.swift`; the previous task's tests pass

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 3: User Story 1 - Two windows on screen, two correct readings (Priority: P1)

**Purpose**: Goal: the windows call, per-window extraction, visibility and the fallbacks. Independent Test: a synthetic capture with a calendar, a mail window and a text-heavy window behind them gives items only from the first two, each dated by its own window.

- [ ] T011 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowsPromptTests.swift` for the windows call per `contracts/prompts-and-eval.md`: `ExtractionPrompts.windowsPrompt(windows:)` lists key, application, title, frame, visible share and up to 12 lines per window, `windowsVersion` is `windows-v1`, and `ExtractionSchemas.windowsSchema` accepts a full answer, rejects an answer that leaves out a given key or names an unknown key, and keeps the capture-wide fields of the classify answer (application, platform look, theme, remote session)
- [ ] T012 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowPipelineTests.swift` with `FakeModelChatting` and `FakeTextRecogniser`: a screen with a calendar, a mail window and a terminal makes the windows call, one extraction for the mail and none for the terminal; a month grid makes no extraction call; the lines of a window covered by one in front are not given to its extraction; a citation to a line outside its window is discarded as `outside the window`; the number of model calls never exceeds 1 plus the relevant non-month windows; a failed or invalid windows answer takes the old path (classify and one extraction) and records the failure; a capture with no stack or one window takes the old path and its findings equal the old results; every finding carries its `windowKey` Add a six-window capture (SC-004): calls never exceed 1 plus the relevant non-month windows; and a capture with no stack or one full-screen window gives findings identical to the old path with no extra calls (FR-010).
- [ ] T013 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReconcilerWindowsTests.swift`: two findings of one picture that look the same but sit in different windows merge into one item with two sightings; two such findings in the same window stay apart (`same-picture-different`, spec 005); older findings with a nil window key behave as before
- [ ] T014 [US1] Add `windowsPrompt`, `windowsVersion`, `windowsSchema` and the `extract-<kind>-v13` rule "these lines are one window of the screen; cite only these line numbers" to `Packages/MemorriCore/Sources/MemorriCore/Extraction/Prompts.swift` and `Packages/MemorriCore/Sources/MemorriCore/Extraction/Schemas.swift`; the prompt and schema tests pass
- [ ] T015 [US1] Implement the per-window path in `Packages/MemorriCore/Sources/MemorriCore/Extraction/AnalysisPipeline.swift` (visible split, windows call, per-window kind correction, subject region and extraction on the window's lines, month grids by geometry, steps `windows` and `extract:<key>`, citation check per window, old path for no stack, one window or a failed call) and put each window's judgement and reading in `AnalysisResult.windows`; the pipeline tests pass
- [ ] T016 [US1] Scope the same-picture rule to one window in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/Reconciler.swift` and `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ReconcilerApply.swift` (the window key of a finding is read from `findings.window_key`); the reconciler tests pass and every spec 005 test still passes
- [ ] T017 [US1] Make `ImageAnalysisJobRunner` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift` load the capture's windows, pass them to the pipeline, and store the window readings and the window keys of the findings next to the analysis (extend `Packages/MemorriCore/Tests/MemorriCoreTests/ImageAnalysisJobTests.swift`: readings are stored, replaced on reanalysis and removed with the capture)
- [ ] T018 [US1] Teach the eval to draw several windows: `GoldenWindow` gets an optional `stack`, `SyntheticChrome` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticChrome.swift` draws overlapping windows with a menu-bar clock, expected findings can name their `window`, `EvalReport` counts model calls per case and in total; add the synthetic cases `windows-calendar-and-mail`, `windows-calendar-under-browser` (the browser window full of dates and numbers, half covering the calendar) and `windows-two-calendars-same-event` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticCalendars.swift`; update `Packages/MemorriCore/Tests/MemorriCoreTests/SyntheticCasesTests.swift` (count, determinism, the tracked folder equals the generator) and generate them into `eval/golden/synthetic` with `memorri-eval generate-synthetic`
- [ ] T019 [US1] Run `memorri-eval run` before (on the branch base) and after, `memorri-eval compare`, and tune `windows-v1` and `extract-<kind>-v13` until the 28 existing cases stay within 0.02 of their precision and recall and the new cases reach 1.00 on dates and windows (constitution VI); repeat the model trial of `research.md` R11 on the new cases with `qwen3-vl:8b-instruct` and keep the numbers in `research.md` under a `Results` section

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 4: User Story 2 - A calendar on another month is read in that month, or flagged (Priority: P1)

**Purpose**: Goal: month evidence per window, conflicts flagged, nothing silently sure. Independent Test: synthetic month, week and day views on months other than the capture's, with and without a title.

- [ ] T020 [P] [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/DateResolverMonthTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/DateResolverTests.swift` (extend): a title naming one month and a label (`1 abr`) naming a month that is neither the title's month nor its neighbours sets `monthConflict` on every header or cell and the resolved start gets origin `inferred` with reason `month-conflict`; a label for the neighbouring month (the 1st of the next month in a grid) is no conflict; a week or day view whose only month evidence is a title in another month than the capture's is read in that month; nothing naming the month still gives `month-assumed` Also test a year conflict: a title naming 2026 and a header or label naming another year sets `monthConflict` the same way, and a conflicted date reaches `ReviewRules` as a guessed start, so the item gets the reason "Guessed time" (FR-006, FR-007, SC-003).
- [ ] T021 [US2] Add `monthConflict` to `DateHeader` and the conflict check to `monthCells` and `headers` in `Packages/MemorriCore/Sources/MemorriCore/Extraction/DateResolver.swift`, and carry it into the provenance reason `month-conflict` (`headerDay`, `baseDay`, `resolve`); the previous task's tests pass
- [ ] T022 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowPipelineTests.swift` (extend) and then compute the headers and cells of each window from that window's own visible lines only in `Packages/MemorriCore/Sources/MemorriCore/Extraction/AnalysisPipeline.swift`, replacing the whole-screen pass plus the narrowing of the stop-gap: a browser window that names another month does not name the calendar's month; a covered part of the calendar is not read; a calendar with too little visible (no title, no 7 labels) gives guessed dates; two calendar windows on different months are each read in their own
- [ ] T023 [US2] Add the synthetic case `windows-month-other-month-menu-clock` (a month view on another month beside a mail window, menu-bar clock showing the capture date) in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticCalendars.swift`, generate it into `eval/golden/synthetic`, run the eval for it and for `calendar-month-other-month-es`, and record the result in `research.md`; every entry must be in the window's month and none flagged

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 5: User Story 3 - The date a window thinks it is (Priority: P2)

**Purpose**: Goal: the reference clock from the window's surroundings or the screen. Independent Test: a synthetic remote-desktop window whose clock differs from the Mac's, with a mail saying "tomorrow".

- [ ] T024 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReferenceClockTests.swift` per `research.md` R4: `ReferenceClock.find` reads a clock text with weekday and date and time (`Thu 1 Oct 20:31`, `Jue 1 oct 20:31`, `Thu 10/1/2026 11:01 AM`), takes the window's own surroundings (the top or bottom 6% of a window marked remote) before the desktop's menu bar (the top 3% of the picture) before the capture time, uses a clock that is hours off the capture time without flagging it, ignores a clock more than 24 hours from the capture time (source `captureFarClock`, `isGuess` true), uses the capture time when no clock can be read, and takes a clock without a date on the capture's date in its own time Also test a capture with no stack: the top 3% strip of the whole picture is searched for the clock, and when none is found the reference is the capture time with `isGuess` false (spec FR-005 exception); with windows known and no clock, `isGuess` is true.
- [ ] T025 [US3] Implement `ReferenceClock` in `Packages/MemorriCore/Sources/MemorriCore/Windows/ReferenceClock.swift`; the previous task's tests pass
- [ ] T026 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/DateResolverTests.swift` (extend) and then make `ResolutionContext` use the reference clock as the "today" of relative dates ("today", "tomorrow", weekdays, end of week) in `Packages/MemorriCore/Sources/MemorriCore/Extraction/DateResolver.swift` and `Packages/MemorriCore/Sources/MemorriCore/Extraction/AnalysisPipeline.swift`: "tomorrow" resolves from a clock hours away from the capture time; a far or unreadable clock resolves from the capture time and the dates that depend on it get origin `inferred` with reason `reference-assumed`; `image_analysis.reference_at`, `reference_source` and `windows_read` are stored by `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisResultStore.swift` Also assert that a date marked `reference-assumed` reaches `ReviewRules` as a guessed start or due, and that a capture with no stack and no clock gives no such mark (FR-010).
- [ ] T027 [US3] Add the synthetic case `windows-remote-clock-other-zone` (a remote-desktop window with its own taskbar clock in another zone and a mail saying "tomorrow") in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/SyntheticCalendars.swift`, generate it, run the eval and record the result in `research.md`; the relative dates must resolve against the remote clock

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 6: User Story 5 - The library is re-read, and cost stays under control (Priority: P2)

**Purpose**: Goal: the one-off background re-read, reuse of stored steps, identical results without a stack. Independent Test: re-read a scratch library with a deleted picture and an edited item.

- [ ] T028 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/LibraryRereadTests.swift`: `LibraryReread.enqueueIfNeeded` queues one `reread` job with `priority` 1 for every capture image that has an analysis and a stored picture, skips pictures that are gone, queues nothing when `library-reread-version` is already current, sets it after queueing, and a priority 0 job created later still runs first
- [ ] T029 [US5] Implement `LibraryReread` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/LibraryReread.swift`, the setting key, and the call at launch in `App/AppEnvironment.swift`; the previous task's tests pass
- [ ] T030 [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/RereadJobTests.swift` and then add the `reread` kind to `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift` (and register it in `Packages/MemorriCore/Sources/MemorriCore/Analysis/CompositeJobRunner.swift`): the stored text is reused (the recogniser is not called), the windows call and the extractions are made afresh, findings are saved, reconciled and evidence is written; a value the user edited, locked, approved or dismissed is unchanged afterwards (use `ItemOperations`); a job whose picture is gone finishes with nothing changed; jobs persist, so a restarted queue resumes where it stopped
- [ ] T031 [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ImageAnalysisJobTests.swift` (extend) and then reuse stored steps in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift` per `research.md` R9: a retry reuses the stored windows answer when the window keys, frames and prompt version are unchanged, and the stored `extract:<key>` run of each window; a forced job redoes all; no model call is repeated for an unchanged capture
- [ ] T032 [US5] Write a test in `Packages/MemorriCore/Tests/MemorriCoreTests/WindowPipelineTests.swift` that analyses the existing eval pictures once with a single full-screen window and gets findings identical to the old path (the no-stack case is covered in the pipeline tests above), and extend `memorri-eval compare` in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalReport.swift` to print model calls and seconds per case; the existing 28 cases must show no change in calls for one-window captures

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 7: User Story 4 - See which window an item came from (Priority: P3)

**Purpose**: Goal: window names with sightings and evidence, cut-outs that show the window. Independent Test: a capture with two windows; each sighting names its window and its cut-out is that window.

- [ ] T033 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvidenceGeometryTests.swift` (extend) for `EvidenceGeometry.region(lines:window:pictureWidth:pictureHeight:)` per `research.md` R10a: a window not larger than 1400 x 800 gives its frame clipped to the picture; a larger window gives a 1400 x 800 rectangle centred on the cited lines (with the margin of spec 006), shifted to stay inside the frame and holding the cited lines when they fit; the region never leaves the frame; `EvidenceGeometry.version` is 3 and findings without a window keep the picture-share rule
- [ ] T034 [US4] Implement the window region and version 3 in `Packages/MemorriCore/Sources/MemorriCore/Evidence/EvidenceGeometry.swift` and use it in `Packages/MemorriCore/Sources/MemorriCore/Evidence/EvidenceWriter.swift` (the window frame comes from `window_readings` through `findings.window_key`; older rows are made again by the existing remake pass); extend `Packages/MemorriCore/Tests/MemorriCoreTests/EvidenceWriterTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/EvidenceBackfillTests.swift` (a version 2 cut-out of a finding with a window is made again while its picture is stored and kept when it is gone)
- [ ] T035 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvidenceLifecycleTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/ReconcilerWindowsTests.swift` (extend): a sighting copies `window_app` and `window_title` from its finding's window, evidence copies them too, both stay with the item after the capture is deleted by retention, `Delete everything` removes the evidence rows with their window names, and a capture without windows leaves them null
- [ ] T036 [US4] Copy the window's application and title into sightings in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ReconcilerApply.swift` and into evidence in `Packages/MemorriCore/Sources/MemorriCore/Evidence/EvidenceWriter.swift`, read them in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemStore.swift` (`SightingRow`) and `Packages/MemorriCore/Sources/MemorriCore/Evidence/EvidenceStore.swift` (`EvidenceRecord`); the previous task's tests pass
- [ ] T037 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemListModelTests.swift` for `ItemListModel.windowText` (`"<app> — <title>"`, `"<app>"` when there is no title, nil when there is no window), implement it in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemListModel.swift`, show it on every evidence card in `App/Windows/EvidenceViews.swift`, and update `specs/006-items-ui-evidence/contracts/ui-contract.md`'s as-built notes

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Phase 8: Polish and cross-cutting

**Purpose**: Measurements, decisions, documentation and a PR a reviewer can trust.

- [ ] T038 Run the whole eval before and after on `qwen3-vl:8b-instruct`, `memorri-eval compare`, and write a `Results` table into `research.md` for SC-001 to SC-007 and SC-009 with the measured numbers (precision and recall per case, model calls per capture, mean seconds per case against the +25% limit); mark any miss plainly as a known gap
- [ ] T039 Run `swift test --package-path Packages/MemorriCore` (all pass, no new warnings), a clean Debug build and a Release build (no debug ingest switches), and grep the diff for real names, company names, user names, e-mail addresses and window titles seen in the user's real captures; confirm `git ls-files eval` changed only by the new synthetic cases; check that no log line in `Packages/MemorriCore/Sources/MemorriCore/Windows` or `Packages/MemorriCore/Sources/MemorriCore/Analysis` prints a window title or a clock text Search the whole core and the app (including `Reconciliation`, `Evidence` and `App/`), not only `Windows` and `Analysis`, for log calls that carry a window title, window name or clock text (FR-009).
- [ ] T040 With the user's go-ahead and their own copy of the app closed, run the library re-read on their real library (counts only: how many captures re-read, how many calendar views on a month other than the capture's are now in that month or flagged, how many items changed, locked and approved values unchanged) and record the counts in `research.md` for SC-008 and SC-009; never print or store titles, names or screen text
- [ ] T041 Run `specs/011-window-aware-analysis/quickstart.md` in the app with an isolated home (`CFFIXED_USER_HOME` set to a scratch folder), ingesting the synthetic multi-window cases with `--ingest-case`: check that the window name shows on each evidence card, that the cut-out is the window, that a launch with an old library queues the `reread` jobs once, and that new captures are analysed before them; take screenshots by window id and buttons through accessibility only; delete the scratch data afterwards
- [ ] T042 Set ADR `docs/architecture/decisions/0022-window-aware-analysis.md` to Accepted with the measured figures, update `CLAUDE.md` (stack paragraph: windows), `DEVELOPER.md` (how a capture is split into windows, the `reread` jobs and `library-reread-version`, how to add a window kind or change the windows prompt with the eval), `docs/roadmap.md` (011 Done once everything passes) and tick the follow-ups of `docs/postmortems/2026-10-01-month-view-read-as-the-capture-month.md`
- [ ] T043 Update `specs/011-window-aware-analysis/contracts/*.md` where the code differs (an "As built" section), then write `specs/011-window-aware-analysis/pr-description.md` (what changed and why, spec and ADRs linked, how it was verified with the numbers, what a reviewer should look at, known gaps); do not push or open a PR until the user asks

**Checkpoint**: tests pass and the checks named above hold before the next phase.

---

## Dependencies and order

- Phase 1 before everything; Phase 2 before the stories.
- US1 (Phase 3) is the MVP and the base of the others: the windows call, per-window extraction and the fallbacks.
- US2 and US3 build on US1's pipeline and can follow in either order; US3's reference clock touches the same date resolver as US2, so do US2 first.
- US5 needs US1; its re-read is what corrects the library, so ship it with or right after US1 to US3.
- US4 needs Phase 2's window key and US1's stored readings.
- Within a story: tests, then code, then eval or app, then the quickstart check.
- Phase 8 after all stories.

## Parallel opportunities

- Phase 1: the migration tests and the job-priority tests.
- Phase 2: the three test files (`VisibleScreenTests`, `WindowReadingStoreTests`, `AnalysisResultStoreTests`).
- US1: the prompt, pipeline and reconciler tests can be written together.
- US2: the date tests and the pipeline tests touch different files.
- US4: the geometry tests and the lifecycle tests.

## Implementation strategy

1. **MVP**: Phases 1 to 3: windows are sorted and read on their own, old captures and failures take the old path. Commit and run the eval at the checkpoint.
2. **Dates**: US2 and US3: conflicts, per-window context and the reference clock, each with its synthetic case.
3. **Library**: US5: queue priority, the one-off re-read, reuse of stored steps, cost report.
4. **Visible trace**: US4: window names and window-shaped cut-outs.
5. **Polish**: measurements, real-library check with the user's go-ahead, ADR, docs and the PR description.
