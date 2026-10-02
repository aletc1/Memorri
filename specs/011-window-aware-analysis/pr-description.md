## What changed and why

A capture shows several windows, but one classification and one extraction read the whole picture, so text from one window decided things about another. A calendar on February was read as October because of it. This reads each window on its own (spec 011, ADR 0022).

- **Windows**: the stored windows (frame, stack order) are split into what is visible of each; each text line goes to the frontmost window that holds it. Without a stack, with one window, or when the windows call fails, the old single-picture path runs unchanged.
- **Analysis**: one `windows` call (replaces `classify`) says which windows can hold events and of what kind; each relevant window is extracted alone (`extract-<kind>-v13`, only its lines and its own cut of the picture); month grids are read by geometry with no call.
- **Dates**: relative dates use the nearest clock (the window's own for a remote desktop, else the menu bar's, else the capture time). A date whose month or year nothing names is flagged and goes to the Inbox; a window whose title and cells disagree is a `month-conflict`.
- **Items and evidence**: findings record their window; sightings and evidence keep its application and title (also after retention), the evidence card shows them, and the cut-out is the window (or 1400 × 800 of a larger one).
- **Library**: a one-time `reread` job per stored capture runs at low priority behind new captures, reusing stored text and unchanged steps; edited, locked, approved and dismissed values stay.
- **Storage**: migration v8 (`window_readings`, window columns, job priority).

Spec: `specs/011-window-aware-analysis/`. ADR: `docs/architecture/decisions/0022-window-aware-analysis.md`. Postmortem follow-ups ticked: `docs/postmortems/2026-10-01-month-view-read-as-the-capture-month.md`.

## How it was verified

- `swift test --package-path Packages/MemorriCore`: 1222 tests pass. Debug and Release builds succeed; the Release binary has no ingest switches.
- Whole eval on `qwen3-vl:8b-instruct`, before (`875508a`) and after, with `memorri-eval compare`: the 28 older cases are unchanged (precision 0.843, recall 0.878, field accuracy 0.908), model calls 52 and 52, mean seconds per case 8.64 and 8.65 (+0.06%). The five new window cases (generated, tracked) score 1.00 precision and recall; only the `place` of three events whose window does not show it differs. `minicpm-v4.5` gets 9 of 16 on them, so one model stays. Table in `research.md` (Results).
- Quickstart run in the app with an isolated home on synthetic cases: windows stored, sightings and evidence name their window, evidence geometry 3, a relaunch queued `reread` jobs at priority 1 and a new capture ran before the second of them.
- Real library, counts only: 15 re-read jobs finished, none failed; the month view checked against its picture is dated right.
- Diff grepped for real names and window titles (none; golden files are drawn); no log line carries a window title or clock text.

## For the reviewer

- `Extraction/AnalysisPipeline.swift` (windows path, reuse, `Geometry.cut`), `Windows/VisibleWindows.swift` and `Windows/ReferenceClock.swift`.
- `Analysis/ImageAnalysisJob.swift` and `Analysis/LibraryReread.swift` (what a re-read keeps and redoes).
- `Evidence/EvidenceGeometry.swift` (version 3; older cut-outs are made again while their picture is stored).
- `Storage/Migrations.swift` v8.

## Known gaps

- SC-008 rests on few real cases (9 captures, 3 month views); the library has no edited, locked, approved or dismissed values yet, so that protection is shown by tests only.
- The `place` of an event is only read where its window shows it.
- Real screens will be harder than drawn ones.
