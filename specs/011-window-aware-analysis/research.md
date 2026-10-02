# Research: window-aware analysis

## R1. Visible windows

- **Decision**: from `capture_windows` (stack order, frame in picture pixels), each window's visible region is its frame minus the union of the frames of the windows in front, as a list of rectangles. A recognised line belongs to the window whose visible region holds its centre; lines in no window are the **desktop** (menu bar, dock, wallpaper text). Windows whose visible area is under 2% of the picture or that hold fewer than 3 lines are dropped. Windows of the app itself (Memorri) and of the system UI (Dock, Window Server, Control Centre) are dropped by bundle id. A capture with no stack, or one window, is one window covering the picture (FR-010).
- **Rationale**: FR-001; rectangles are exact for the window model the system gives; the centre rule matches the stop-gap's `visibleLines`, whose tests carry over.
- **Alternatives**: masks per pixel (no gain over rectangles); asking the model to find windows (costly, imprecise).

## R2. The windows call (sorting)

- **Decision**: one call per capture, step `windows`, prompt `windows-v1`, on the classification-size picture with a numbered list of the visible windows: key, application, title, frame, visible share, and up to 12 of its lines. The schema answers per window `{key, relevant, kind, confidence, calendar_name}` plus the capture-wide fields of today's classify answer (application of the frontmost relevant window, platform look, theme, remote session) so tags and context matching keep their inputs. The model decides every window (clarification 5). `relevant` is false for windows that cannot hold events. If the call fails or the answer does not name the windows given, the capture takes the old path (classify + one extraction) and the failure is recorded.
- **Rationale**: FR-002, FR-011 (the call replaces classify, so a one-window capture costs what it costs today); one call sees the whole screen, which the model needs to tell a remote desktop or a dialog apart.
- **Alternatives**: one classify call per window (N calls, SC-004 fails); app-name rules (rejected by the user).

## R3. Reading one window

- **Decision**: per relevant window, the window's lines (keeping their global line numbers so citations, evidence and the stored OCR stay valid) and the window's cut of the analysis picture are passed to the existing extraction for its kind (prompt `extract-<kind>-v13`: v12 plus "this is one window; only cite these lines"). Month grids are read by geometry from the window's lines (ADR 0018), no call. Kind correction (`corrected`) and the subject region run on the window's lines. Citations to lines outside the window are discarded like citations to missing lines.
- **Rationale**: FR-003, FR-004; smaller pictures and fewer lines make each call faster, offsetting the extra calls (SC-004).

## R4. Reference clock

- **Decision**: clock texts are lines that parse as a date with a time or as a time next to a weekday or date (`Jue 1 oct 20:31`, `Thu 10/1/2026 11:01 AM`, `20:31` under `01/10/2026`). Sources in order: inside the window's own surroundings (a remote-desktop window's taskbar strip: the bottom or top 6% of a window marked `remote` by the windows call), then the desktop's menu bar (desktop lines in the top 3% of the picture), then the capture time. A clock without a date takes the capture's date in its own time; a clock more than 24 h from the capture time is ignored and the dates that depend on the reference get `reference-assumed` (FR-005, clarification 2). The time zone stays the context's (or the Mac's); the clock gives the reference instant.
- **Rationale**: Story 3; the menu bar is always present on a normal capture and is the cheapest exact reference.

## R5. Month evidence and conflicts

- **Decision**: per window, the month evidence is the title (`monthTitle`), labels naming a month (`1 feb`), and headers with a month. The stop-gap's order stays (title over grid, then labels, then the capture's month with `month-assumed`). New: when a title and a label in the same window name months that cannot both be right (the label is not in the title's month or its neighbours), every date of the window gets `month-conflict` and `inferred` (FR-007).

## R6. Storing what a window was

- **Decision**: `window_readings` keeps, per picture and window key, the application, title, frame, visible share, relevance, kind and confidence, and the model run. `findings.window_key` names the window; `sightings.window_app`, `sightings.window_title`, `evidence.window_app`, `evidence.window_title` copy it (evidence outlives its capture, clarification 4). The window key is the stack index at capture time (`w0`, `w1`, …; `all` for one-window captures).
- **Rationale**: FR-009, R9 reuse; copies mirror how evidence copies the sighting's details in spec 006.

## R7. Reconciliation across windows

- **Decision**: reconciliation runs once per picture on the findings of all its windows, as today. The rule that keeps two findings of the same picture apart when uncertain (`same-picture-different`) applies only within one window: two windows of one picture may show the same event (Story 1, scenario 4). Everything else in spec 005 is unchanged.

## R8. Library re-read (FR-011a)

- **Decision**: once, after the update (setting `library-reread-version` below `windows-v1`), every capture image with a stored picture and an analysis gets a job of kind `reread` with `priority = 1`; the queue orders by `priority, created_at`. A `reread` reuses the stored OCR lines, makes the windows call and the extractions afresh, saves, reconciles and writes evidence like `analyse`. Pictures whose files are gone are skipped (the job ends `finished` with nothing changed). Locks, approvals and dismissals live on items and are not touched by reanalysis (spec 005/006). The jobs persist, so a restart resumes.
- **Alternatives**: `not_before` in the future (waits even when idle); spec 008 (not built; the user asked for it now).

## R9. Reuse and cost

- **Decision**: a retry (not forced) reuses the stored windows answer when the window list is the same (same keys and frames) and the prompt version matches, and the stored extraction run of each window by step name `extract:<key>`. Model calls: 1 (windows) + one per relevant window that is not a month grid.

## R10. Evaluation

- **Decision**: `SyntheticChrome` learns to draw several windows (with stack order and frames in `meta.json`, including a menu-bar clock): calendar + mail side by side; calendar half under a browser full of dates and numbers; two calendar windows sharing an event; a remote-desktop window with its own taskbar clock in another zone; a month view on another month with a menu-bar clock. `GoldenWindow` gains an optional `stack`. Scores per case as today, plus model calls per case in the report (SC-004).
