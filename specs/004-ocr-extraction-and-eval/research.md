# Research: Read captures and find appointments and tasks, measured against a golden set

Each item: Decision, Rationale, Alternatives. Items marked **Spike** are questions only the real system can answer; the first tasks prove them on this Mac before the rest is built on them (same approach as specs 002 and 003). Facts were checked on 2026-09-30 on this Mac (macOS 26, Ollama 0.34.4).

## R1. Text recognition

- **Decision**: Vision's Swift request `RecognizeTextRequest` (checked: it compiles and runs here), `recognitionLevel = .accurate`, language correction on, automatic language detection on, run on the full-resolution picture decoded from the stored HEIC. Each observation becomes a line: text of the best candidate, confidence, and a box converted from Vision's normalised bottom-left coordinates to integer pixels with a top-left origin in the picture's own size. Lines are numbered 1 to n in reading order: rows by top edge with a tolerance of half the median line height, then left to right, so numbers are stable for the same lines. A picture with no observation is stored as read with zero lines.
- **Observed**: on a 680 x 632 synthetic screenshot, 25 lines with exact text and boxes; the first call after process start took 43 s (model loading), so the first analysis after launch is slow and later ones are expected to take seconds. Spike S1 measures warm times at full size.
- **Rationale**: Exact boxes come from the recogniser, not from the model (ADR 0004). Reading order makes the numbered list the model sees read like the screen.
- **Alternatives**: the older class-based request (works, but the Swift request is the current API), no language correction (spike S1 compares both on codes, emails and times, where correction can hurt), a third-party recogniser (new dependency, no gain).
- **Spike S1 result (2026-09-30)**: 86 of 89 drawn strings exact with language correction on (83 with it off), 84 boxes overlapping; warm time about 0.2 s per 2400 x 1500 picture; single-digit cells in a month grid are the weak spot. Decision: correction on. See `spike-report.md`.
- **Spike S1 (design)**: for the drawn golden pictures at native size and degraded the way a remote session degrades them (scaled to 75% and JPEG quality 0.4): exact-text rate, box overlap, warm time per picture, language correction on and off. Decision feeds SC-003.

## R2. One job per picture, steps that resume

- **Decision**: A new job kind `analyse` (no schema change: `analysis_jobs.kind` has no CHECK). The capture step enqueues one job per stored picture when automatic analysis is on. The runner performs steps in order and stores each result as soon as it exists: `read` (skipped when `ocr_reads` has a row), `classify` (skipped when the picture's classification is stored for the current classifier version), `extract`, then `resolve` (code only, in one transaction with storing findings, tags and context). Retries (spec 003: 3 attempts, 10 s then 60 s) therefore resume at the failing step. A job dispatches through a `CompositeJobRunner` by `kind`; `test` jobs keep their runner.
- **Rationale**: Reading is cheap and classification is a small call, but the extraction call is the slow one; a failed extraction must not redo the others. One job per picture keeps the menu counts meaningful ("Analysing 1 of 3").
- **Alternatives**: one job per step (more rows, cross-job ordering rules), no intermediate storing (a failure at the last step repeats a 10 s call).

## R3. Two model calls and the picture cache

- **Decision**: Call 1 (`classify`) sends the analysis copy and a short prompt; the schema returns `screen_kind` (one of the seven), `kind_confidence`, `application`, `platform_look`, `remote_session {is_remote, client}`, `theme`, `calendar_name`. Call 2 (`extract`) sends the same picture, the numbered lines and the prompt for the kind. Both use the native `format` (ADR 0013), temperature 0, the think setting from spec 003, and the JPEG conversion of the stored HEIC.
- **Rationale**: the prompt for a week view differs from one for an email, and the visual tags are only a few tokens more on the first call. Spec 003 measured repeats of the same picture at 1 to 3 s versus 9 s for a new one at 1536, so the second call is expected to be cheap if the server reuses the picture work.
- **Spike S2 result**: the second call did not reuse the picture work in any arrangement (about 20 s for a new picture at 2048 for each call), so the cost is two passes. Classification at 1024 pixels takes about 6 s with the same accuracy on the drawn set, so **call 1 is sent at 1024 pixels and call 2 at the configured size**; one user message with the picture, positions kept. See `spike-report.md`.
- **Spike S2 (design)**: with drawn pictures and their numbered lines, measure: schema-valid rate of both calls, share of findings with valid citations, time of call 2 when sent right after call 1 with the picture first versus the text first in the message, and whether three levels of line detail (text only, text with line box centre as percentages) change citation accuracy. The cheapest arrangement that keeps the scores becomes the default (ADR 0014).

## R4. Prompts and schemas per screen kind

- **Decision**: `ExtractionPrompts` holds one prompt per kind plus a general one for `other`, each with a version string `extract-<kind>-v1`; `ExtractionSchemas` holds the matching schemas (`schema-<kind>-v1`). A finding in every schema: `kind` (`appointment`, `task`, `reminder`, `deadline`), `title`, `cited_lines` (integers, at least one), optional literal texts `start_text`, `end_text`, `date_text`, `due_text`, `remind_text`, `all_day`, `people`, `place`, `notes`. Week and day schemas add `column_line` (the number of the header line above the finding's column, when visible). Email schemas add `sent_text`. Chat schemas add `message_time_text`. Prompts say: use only what is on screen; cite the lines that show each fact; copy dates and times as written; "X needs Y" is a task for X; never invent. The lines are given as `L<n> (x%,y%) text`, capped at 600 lines (drop those with the smallest boxes first) and the cap is recorded.
- **Rationale**: Literal texts keep date arithmetic out of the model (R6). Versions in every run record make reprocessing (spec 008) and the eval gate auditable.
- **Alternatives**: one schema for all kinds (the week view needs the column cue; email needs sent time for "tomorrow"), letting the model return ISO dates (errors in arithmetic and time zones cannot be tested).

## R5. Checking answers and citations

- **Decision**: Every answer goes through `SchemaValidator` (spec 003). A finding with no `cited_lines`, or citing a line number that is not in the picture, is discarded and recorded in `image_analysis.discarded_json` with its title and reason; the rest are kept. An answer that fails the schema is a transient failure (queue retry). The confidence of a finding is the lowest confidence among its cited lines, lowered to at most 0.5 when any field is inferred.
- **Rationale**: Citations are what make evidence crops and audits possible (Constitution II); discarding bad findings is safe and visible.

## R6. Date and time resolution (deterministic)

- **Decision**: `DateParser` turns literal text into parts (weekday, day, month, year, time with am/pm or 24 hour, relative words) using month and weekday names for English and Spanish (this Mac's language) first, taken from `Calendar`/`DateFormatter` symbols so more locales are added by name; the tag `language` and the Mac locale select the order of tries. `DateResolver` applies these rules in order and records the rule id: `explicit-date` (full date in the text), `header-column` (for week and day views: the finding's first cited line is matched to the nearest header line by horizontal centre; the header gives the date), `relative-day` (today, tomorrow, yesterday, "in N days", "next Monday"), `end-of-week` (the Friday of the reference week), `weekday-only` (the first occurrence on or after the reference date, or the header's week when present), `time-only` (the reference date), `deadline-reminder` (for a deadline with an action and no reminder text: 09:00 local on the working day before the due date, inferred), `unresolved` (kept as written and flagged). The reference date is the capture time converted to the context's time zone (or the Mac's zone when unassigned or invalid). The reference for emails is the email's own `sent_text` when it parses, else the capture time. A numeric date with an ambiguous order (03/04) takes the order of unambiguous dates in the same picture, else the tag `date_order`, else the Mac locale, and is marked inferred with the reason `date-order`.
- **Rationale**: Testable table-driven logic (SC-005) instead of model arithmetic; the rule id is the provenance for evidence (Constitution II); a capture just after midnight in another zone resolves against that zone's date.
- **Alternatives**: `NSDataDetector` (good for plain dates, cannot use headers or zones or explain itself), asking the model for ISO dates.

## R7. Durations from block geometry

- **Decision**: `BlockGeometry` works on the full-resolution pixels and the recogniser's lines, only for `calendar_week` and `calendar_day`. (1) Hour scale: lines whose text is a clock label (`9 AM`, `09:00`, `10:00`) in the same narrow column are collected; a least-squares line from label centre y to minutes gives the pixels per hour; fewer than two labels means no geometry. (2) Block bounds: take the box of the finding's first cited line, sample the colour just inside its left edge, region-grow over similar colours (tolerance in Lab) bounded to a window the width of one column, and take the region's vertical extent; it counts only if the region is larger than the line box, not wider than a column and not the page background. (3) Height to minutes through the fit, rounded to 15 minutes, limited to 30 minutes and 12 hours. Any failure gives 60 minutes with the rule `default-60`. The result is flagged inferred with the reason `block-height` or `default-60`. An explicit end in the text is used as read.
- **Rationale**: Edges of a block are not text, so the recogniser cannot give them and the model's coordinates are unreliable (ADR 0004); colour regions are a cheap, testable method on drawn calendars.
- **Spike S3 result**: solid-fill blocks exact; outlined, rounded and degraded dark styles mostly return nothing and use the default; sanity checks (colour agreement, width 3 title heights to one column, 30 to 720 minutes) are required because a seed on a gridline gave a wrong 540-minute value. See `spike-report.md`.
- **Spike S3 (design)**: measure duration error on drawn week views in several styles (solid blocks, outlined blocks, rounded corners, overlapping blocks, dark theme) at native size and degraded; report how often the method returns a value and its error in minutes; if it is unreliable for a style, that style uses the default and the report says so (SC-006 needs the flag to be right, not the guess to be perfect).

## R8. Tags

- **Decision**: Keys and sources. From the capture (code): `display_size` and `display_scale`; from window titles (code): `window_app` (owning application name and bundle id), `window_title_keywords`, `remote_client` when the owning application is a known remote-desktop or virtualisation client (a small list kept in code: Citrix Viewer, Microsoft Remote Desktop and Windows App, VMware Horizon, Parallels, Jump Desktop, Teams and browsers are not in it). From the lines (code): `language` (`NLLanguageRecognizer` over the lines), `clock_style` (12 or 24 hour by counting times with and without am/pm), `date_order` (dmy, mdy, ymd from unambiguous dates), `account` and `domain` (email addresses and domains found in lines, source the line number), `timezone_label` (GMT+2, CEST, UTC-5, and city names in calendar zone pickers). From call 1 (visual): `application`, `platform_look`, `remote_session`, `theme`, `calendar_name`. Every tag stored with a confidence and a source (`code`, `window`, `line:<n>`, `visual`); a visual tag below 0.6 is stored as `low`. Unknown is not stored. A finding's `tags_json` is a copy of the picture's tags at that run.
- **Rationale**: code-derived tags are exact and cheap; only what needs eyes uses the model, in a call that already exists (spec US8).
- **Alternatives**: a third model call for tags (extra time per picture), model-only tags (no provenance, no tests).

## R9. Window titles at capture time

- **Decision**: `ScreenCaptureKitCapturer` already fetches `SCShareableContent.current`. It takes the on-screen windows at layer 0 whose frame intersects each display and returns up to 20 per display, largest visible area first, as `WindowInfo` (application name, bundle id, title, frame in the picture's pixel space). `CapturedDisplay` gains `windows` (default empty, so existing fakes are unchanged). `CapturePipeline` stores them in `capture_windows` in the same transaction as the images. No extra permission is needed beyond Screen Recording.
- **Spike S4 result**: titles are present for every window on this Mac; the call costs about 54 ms; no remote client to test. See `spike-report.md`.
- **Spike S4 (design)**: with the permission this app already has, check that titles are non-empty for a browser, Mail and Calendar, what a full-screen remote-desktop client reports (application name, title), and that the added cost to the capture step is a few milliseconds. If titles are blank, `window_title_keywords` stays empty and the application name still works.

## R10. Context matching

- **Decision**: `ContextMatcher` scores each context by its hints: `window_title` (3 points), `app` (3), `domain` (2.5), `keyword` (1), each counted once however often it appears, matched case-insensitively against window titles and application names, tag values (`domain`, `account`, `remote_client`, `window_title_keywords`) and, for `domain` and `keyword` only, the lines' text. A context needs at least 2 points and a lead of at least 1 point over the runner-up; otherwise the picture is unassigned with `source = none` and the candidates recorded (a tie is recorded as `tie`). The matched hints and the runner-up are stored with the assignment. A row with `source = user` is never replaced by reanalysis.
- **Rationale**: transparent, testable, no learning (spec assumption); the thresholds are constants in one place the eval set can tune later.

## R11. Time zone

- **Decision**: a context's time zone is an IANA identifier, validated with `TimeZone(identifier:)`; invalid or missing means the Mac's zone and the picture's analysis records `timezone_source = mac` (or `invalid-context-zone`). Findings store UTC instants plus the zone identifier used; all-day findings store the local midnight and `all_day = 1`.
- **Rationale**: a calendar in a remote session shows the customer's local time (plan from Phase 0); storing the zone keeps the meaning when the Mac moves.

## R12. Storing results and reanalysis

- **Decision**: `AnalysisResultStore.save(result)` runs in one transaction: delete the picture's findings, tags (except user-set context), discards and analysis row; insert the new ones; keep `image_context` when `source = user`. `model_runs` rows of earlier runs stay (they cascade with the capture). Reanalysis is a new `analyse` job whose runner ignores stored steps (`force = true` in the job payload is the job's `kind` value `analyse-force`; no schema change).
- **Rationale**: idempotence (Constitution III): running the same picture twice leaves one set of findings.

## R13. Automatic queueing and the backlog

- **Decision**: `AnalysisSettings.automatic` (key `memorri.analysis.auto`, default true). After `CaptureStore.insert` succeeds, `CapturePipeline` calls an optional `AnalysisEnqueuing` with the new picture ids when the switch is on. Existing captures are not analysed on their own: Settings offers **Analyse stored captures**, which enqueues every picture with no analysis and no waiting job. Pause (spec 003) stops the flow at any time.
- **Rationale**: upgrading must not start hours of model work on a week of old captures; a single button gives the user the choice.

## R14. Eval harness inside the core package

- **Decision**: `Evaluation/` in `MemorriCore` holds loading, matching, metrics, running, reporting and the synthetic generator, all testable. `memorri-eval` is an executable target in the same package (`Sources/memorri-eval`, product `memorri-eval`; a path outside the package root is refused by SwiftPM, checked here) so `swift run --package-path Packages/MemorriCore memorri-eval` from the documentation works. It calls `AnalysisPipeline` with a golden case's picture and metadata instead of a stored capture. Commands in [contracts/eval-cli.md](contracts/eval-cli.md).
- **Rationale**: shared code is what makes the scores mean something (spec US1); one package keeps building simple.

## R15. Busy check

- **Decision**: before any run, `BusyCheck` opens the app's database file read-only (if it exists) and refuses when `analysis_jobs` has a row in state `running`, printing "Pause analysis in Memorri first (or use --allow-busy)". `--allow-busy` runs anyway and the report records `ranWhileAppBusy = true`. A missing or unreadable database counts as not busy.
- **Rationale**: decided in clarification; reading the same file needs no IPC and no change to the app.

## R16. Synthetic golden cases

- **Decision**: `SyntheticCases` draws each case with Core Graphics and Core Text from a specification (layout, application look, theme, language, clock style, time zone label, events with exact times) and writes `screenshot.png`, `meta.json` and `expected.json` whose contents are exact by construction. About 26 cases: each of the seven kinds at least twice; relative dates ("tomorrow", "next Monday", "end of week"); header-column dates in week and day views; "X needs Y" in email and chat; missing durations with blocks of 30, 60, 90 and 120 minutes and text-only meetings; a capture just after midnight in a zone far from the Mac's; a 12-hour and a 24-hour clock; English and Spanish; a remote-session frame (a window with a title bar naming a remote client); Outlook-like, Apple Mail-like, Teams-like and plain web looks; empty and text-free pictures. The generator is deterministic (fixed seeds), so regenerating gives identical files.
- **Rationale**: nothing from the user's sessions enters git; expected results cannot drift from the picture. The limit is realism: drawn screens are cleaner than real ones, so real local cases are welcome and the report separates `synthetic` from `local` cases.

## R17. Metrics

- **Decision**: one-to-one matching by best score (kind equal; title similarity at least 0.80 by normalised edit distance after lowercasing and removing spaces and punctuation, or one title contains the other; start or due within 5 minutes; ties go to the higher similarity). Precision = matched / found; recall = matched / expected; field accuracy = equal fields / compared fields over matched findings (fields: start, end, all-day, due, remind, people as a set, place as normalised text, inferred flags). Also classification accuracy, tag accuracy per key (expected tags are optional per case), the `ranWhileAppBusy` flag, results by kind and by confidence band, and a list of missed and unexpected findings with the nearest candidate. Thresholds are printed and stored in the report.

## R18. Picture size study (user story 9)

- **Decision**: `memorri-eval sweep-size` runs the set at 1024, 1536, 2048 and 3072 (longer side of the analysis copy, made from the case's full picture with the same encoder as the app, then converted to JPEG as the queue does) and prints measures and mean time per picture. The default becomes the smallest size whose findings F1 is within 0.02 of the best and whose field accuracy is within 0.02 of the best; if none is smaller than 2048 the default stays. Recorded in ADR 0017 and applied in `StorageSettings` only as the default, so a user's own choice is kept.

## R19. App pieces

- **Decision**: Settings gets an **Analysis** row: the automatic switch, **Analyse stored captures**, a list of the 20 most recent pictures with state, kind, context, finding count and tag chips, a disclosure with the findings, **Reanalyse**, and a context picker per picture; and a Contexts block (add, rename, delete, time zone, hints). The debug switch `--ingest-picture <png>` (Debug builds only, like `--simulate-free-bytes`) stores a synthetic picture as a capture and enqueues it, so scenarios can run without capturing the user's real screen.
- **Rationale**: the list is the checking aid the spec asks for (FR-018); the ingest switch keeps verification off real content.

## R20. Logging

- **Decision**: category `extraction`: `read image=<id> lines=<n> ms=<n>`, `classify image=<id> kind=<kind> confidence=<x> ms=<n>`, `extract image=<id> kind=<kind> findings=<n> discarded=<n> ms=<n>`, `resolve image=<id> unresolved=<n> inferred=<n>`, `context image=<id> source=<auto|user|none> name=<name|->`. No text from the screen, no titles and no tag values in the log.

## Changes made after the real runs (2026-09-30)

Decisions above stand unless listed here. Each was found by running `memorri-eval` on the synthetic set with the real model and is recorded in `quickstart.md` with the numbers.

- **Dates use the context's zone.** The first full run resolved every date in the Mac's zone, so every week and day case missed by 6 hours. The context step now runs before dates are resolved (R9's order, made explicit) and the synthetic "Customer A" context also carries a `window_title` hint, because calendar views rarely show a domain.
- **Month views (R6 addition).** The rule `month-cell` dates an entry from the day label of the cell it sits in. The grid is inferred from the labels that were read and from their places: a cell whose label the reading missed (single digits are the weak spot of the recogniser, spike S1) still gets its date from its row and column, and the days before the 1st and after the last belong to the neighbouring months because the dates are voted from all labels. The model's `column_line` in a month view is only used for a line with no position. An entry with no time is all day on its cell. Schema `schema-calendar_month-v2` adds `column_line`.
- **All-day banners and month entries with no time** are dated from their column or cell even when the model writes the month's title (or a bare day number) in `date_text`, and even when it does not set `all_day`.
- **Block heights (R7 addition).** The fill colour is the most common colour inside the recogniser's title box (the box is tight, and can start left of the block or sit two pixels below its top edge, so sampling beside or above it failed on most blocks of the drawn pictures); filled blocks are scanned at a column beside the text and their width is measured on a row just inside the top edge; outlined blocks need a border line above and below, each no longer than a column (a longer one is a grid line). A day view has one column: the whole width.
- **Prompts.** Classification prompt `classify-v2` names applications as people do (`Web calendar` for a page in a browser) and asks for the look of the remote desktop inside a window. Extraction prompts `extract-<kind>-v4`: titles use words of the text with no line labels, dates or times; a worked "X needs Y" example; only items with a date, a time or a needs/has-to sentence; everything in a calendar view is an appointment; end times only when the block shows one, never from the hour scale; `place` and `people` (not the sender); in an email only the open message; in a chat the title in the language of the messages.
- **Tags.** The visual tags carry the classification's confidence (the model gives one number), so "low" (below 0.6) is rarely seen; a wrong visual tag therefore counts as wrong with high confidence. `language` needs 0.9 from the recogniser limited to eight languages, and is missing on chrome-less or name-only pictures. `clock_style` counts bare times as a weak `24h` (confidence 0.55) only when nothing in the picture has am or pm. The resolver uses the `date_order` tag and puts the `language` tag's locale first; it does not use `clock_style`.
- **Scoring.** Application and session names match when one contains the other (`Teams`, `Microsoft Teams`). A drawn string counts as read when it is part of a longer recognised line (the recogniser joins a sender and its time). The synthetic cases without any window frame do not expect `platform_look` (nothing in them shows the operating system), and the Spanish email case has a Spanish inbox list so its language is what it says.
- **Size sweep** (R18) runs on the same pipeline; see `spike-report.md` and ADR 0017 for the numbers and the decision.

## Changes made after a real three-display capture (2026-10-01)

A real capture (a chat client, a small display, a month calendar on a 3440 x 1440 display) was analysed in an isolated home. The picture and its output stay untracked; the lessons are general.

- **Big pictures are read in tiles.** One Vision pass over 3440 px read 35 lines; tiles of at most 1800 px with a 160 px overlap read about 450. `TiledTextRecogniser` wraps the recogniser, offsets the boxes and removes repeats from the overlaps (keeps the widest, then the most confident). A picture within one tile is read as before.
- **A calendar's prompt holds only the calendar.** `SubjectRegion` keeps the lines inside the grid (month: the label columns and rows; week: the header columns, below the headers), so text from other windows is not extracted as findings. Lines keep their numbers. The extract timeout scales with the number of lines shown (`90 s + 1.5 s per line`, at most 900 s) because a full month can hold 100+ entries.
- **A month grid survives stray numbers.** Other windows show numbers too (a clock, a page count). `monthCells` keeps only the labels in columns shared with at least a third as many labels as the fullest column. The first of a month is often written with the month ("1 oct"); the recogniser may read just the name, so the cell is synthesised from the grid and a text that is only a day number, with or without a month name, is a cell label, not a date.
- **Calendar entries are appointments.** The model labelled every entry of a month view `deadline` and copied the day number into every text field. In a calendar view the code makes each finding an appointment, and `extract-calendar_month-v7` says so. Measured on the real month view: 169 of 173 findings had a date before the month-name fix (the other 4 were the first of the month).
- **Date fields hold only dates.** In a chat the model put a sentence ("I will look and tell you") in `due_text`. Prompt v7 says the date and time fields hold a date or a time as written, never a sentence. A sentence that is not a date is still kept as unresolved, never invented as a date.
- **Settings.** The window is resizable (size remembered) and a context is a card with labelled rows, so the name and time zone fields are readable.
- **Small text is read at twice its size.** On a 1x display the entries of a month are 11 pixels high. `TiledTextRecogniser` now reads tiles of 900 pixels enlarged 2x: 467 lines and 59 of 59 "Daily" entries against 242 lines and 29 with the old 1800 pixel tiles at their own size. The cost is a few seconds.
- **Lines joined across cells are split** (`LineSplitter`): the coloured bar of an entry is read as `|`, which joined "12:00 | Daily standup" from two cells into one line.
- **Week views that stack the day number over the weekday name** (Teams) are read: `DateResolver.headers` pairs the number with the name under it and fills a column whose number was not read. A picture the model calls month whose date headers run across it, much wider than any grid of day labels, is a week view (`AnalysisPipeline.corrected`).
- **The visual tags are doubted when the windows disagree** (a calendar in Teams read as Thunderbird on Linux over VNC): the tag is kept at low confidence.
- **Month views are read by geometry, not by the model** (ADR 0018, Proposed): complete, exact and under a minute; the model's extract call took 5 to 6 minutes and returned 70% of the entries.
- **The window in front is known.** The capturer records each window's place in the front-to-back order (`WindowInfo.stack`, `capture_windows.stack`, migration v4; empty for captures stored before it). `SubjectRegion` drops the lines that lie inside a window in front of the calendar window, so a popup or a file manager over the calendar is not read as entries. Memorri's own windows are left out of the picture (`SCContentFilter` excluding them).

## Prompt tuning and the default model (2026-10-01)

Six models were run on the 27 synthetic cases (table in ADR 0019). What the tuning showed:
- **The extract prompt is numbered rules, a field contract and examples** (`extract-<kind>-v12`). The earlier paragraph prompts let `qwen3.8:27b-mlx` fall into a loop on dark Teams pictures (a title that repeated the whole screen) and made the small models write a sentence in a date field. v9 moved `qwen3-vl:8b-instruct` from 0.73 / 0.80 to 0.83 / 0.87; v10 to v12 (sharper kind, place, advice and message-list rules; for week views, one item per block and never a time that is not in the lines) changed nothing on that set, so the 8B model is at its plateau there.
- **A time range is split in code.** The models leave "14:00-15:30" whole in `start_text`; `FindingDraft.splittingTimeRange` makes the start and the end.
- **The answer length is capped** (`num_predict`), with room for thinking tokens on models that think: a runaway fails at once, not at the timeout. A first cap that ignored thinking made `qwen3-vl:8b` fail 20 of 27 cases, which was the cap's fault, not the model's.
- **`think: false` does not reach every model.** The field is sent (stored requests show it), but Ollama ignores it for `qwen3-vl:8b`; `qwen3.8` and `gemma4` honour it, `minicpm-v4.5` never thinks. `/no_think` in the prompt does nothing for `qwen3-vl:8b` either. The instruct variant is the non-thinking one.
- **Tuned on the cases that score it.** The numbers are optimistic for real captures. Local web pictures (Apple Calendar, Google Calendar, Teams, open-source calendars; `eval/out/web-pictures/`, git-ignored) are collected for labelled local cases.

