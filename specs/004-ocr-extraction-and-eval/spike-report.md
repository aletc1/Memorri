# Spike report: spec 004

Run on 2026-09-30 on this Mac (macOS 26, Ollama 0.34.4, `qwen3.8:27b-mlx`, think off, native `format`). **Only drawn pictures were used** (five 2400 x 1500 synthetic screens: week calendar, email with reading pane, dark chat, plain document, month grid); nothing from the user's sessions was opened or read. Scripts were throwaway and are not committed.

## S1: text recognition (`RecognizeTextRequest`, accurate, automatic language)

89 drawn strings across the five pictures. "Exact" means a recognised line equals the drawn text; "overlap" means its box overlaps the drawn box by at least 50% of the smaller box.

| Picture variant | Language correction | Exact | Contained in a line | Box overlap | Warm seconds per picture |
|---|---|---|---|---|---|
| native | on | 86 / 89 (96.6%) | 89 | 84 | about 0.2 |
| native | off | 83 / 89 | 88 | 81 | about 0.2 |
| degraded (75%, JPEG 0.4) | on | 84 / 89 | 88 | 82 | about 0.2 |
| degraded (75%, JPEG 0.4) | off | 83 / 89 | 88 | 81 | about 0.2 |

- The misses were isolated single-digit day numbers in the month grid (a `3` read as a Cyrillic letter, two digits not found) and two lines that looked wrong only because the same text appears twice in the picture; all multi-character text was exact.
- The first call after process start took 43 s (model load in Vision); later calls about 0.2 s. The first analysis after each app launch pays this once.
- **Decisions**: language correction **on**; automatic language detection on; run on the full-resolution picture. Single-digit cells are a known weak spot (month view day numbers), so date logic must not depend on reading every day number. Warm-up: run the recogniser once on a tiny picture at launch is not needed; the first job simply takes longer.

## S2: the model with numbered lines

Lines given as `L<n> (x%,y%) text` (or `L<n> text` without positions), classification call then extraction call, native `format`, JPEG 0.9. Synthetic content only.

| Arrangement and size | Classification | Extraction | Seconds, new picture: call 1 / call 2 | Notes |
|---|---|---|---|---|
| One user message with the picture and the prompt, 2048, with positions | week, email, chat correct (5 of 5 runs each) | every finding cited existing lines; all expected findings found (week 3/3, email 3/3, chat 2/2) | 17 to 23 / 20 to 22 | repeats of the same request 2 and 5 to 7 (server cache) |
| Same, 2048, without positions | correct | citations valid; email found 2 of 3 expected | 17 / 18 to 21 | positions help a little; kept |
| Same, **1024** | week, email, chat, document correct | valid citations; same findings as at 2048 (week 3/3, email 3/3, chat 2/2) | **6 / 8 to 13** | month view at 1024: a request ran past 300 s (timeout) |
| Picture in its own first message, then the prompt as a second user message | (first call hung past 600 s under the schema) | | | rejected |
| Picture message, short assistant turn, then the prompt (multi-turn), 2048 | correct | valid | call 2 after a new picture: 17 to 20 | the second call did **not** reuse the picture work |
| Prompt in a system message, picture in the user message | not measured (the first arrangement already met every target) | | | |

- Classification accuracy 100% (5 of 5 kinds) in every arrangement that finished; schema-valid answers 100%; citations valid in every finding (no invented line numbers).
- **The second call is not cheap.** For a new picture call 2 took as long as call 1 (about 20 s at 2048); the server did not share the picture work between two different prompts in any arrangement tried. Repeats of an identical request are fast (2 to 6 s).
- The document picture produced two findings although no appointment or task was expected (it listed a "next steps" sentence); precision on such pictures is a prompt question for the eval set, not a blocker.
- A timeout is a real failure mode: a dense month grid at 1024 ran past 300 s. The queue's retry and timeout handle it (transient failure).
- **Decisions**: one user message with the picture and the prompt (no system message, no multi-turn). Keep the position percentages. **Send the classification call at 1024 pixels** (about 6 s) and the extraction call at the configured analysis size (2048 until the size study, user story 9). Total about 26 s per picture instead of about 45 s. The classification confidence below which a picture counts as `other` stays **0.5** (no value below 0.9 was seen on the drawn pictures).

## S3: block height from pixels

Week views in five styles with blocks of 30, 60, 90 and 120 minutes (plus overlapping blocks), native and degraded. The method: hour scale from the clock labels, then a colour run around the first cited line. After adding sanity checks (the colour at the left of the title and just above it must agree; the horizontal extent at the row above the title must be at least 3 title heights and at most one column; vertical extent between 30 minutes and 12 hours), the last run gave:

| Style / variant | Blocks | Value returned | Mean error (minutes) |
|---|---|---|---|
| solid fill, native and degraded | 8 and 8 | 8 and 8 | 0 |
| dark theme, native | 8 | 8 | 3.8 |
| dark theme, degraded | 8 | 0 | |
| overlapping blocks, native | 12 | 10 | 0 |
| overlapping blocks, degraded | 12 | 10 | 6 |
| rounded corners, native | 8 | 4 | 0 |
| rounded corners, degraded | 8 | 0 | |
| outlined, native | 8 | 1 | 0 |
| outlined, degraded | 8 | 3 | 0 |

- Without the sanity checks a seed that landed on a column gridline returned a 540-minute block (a wrong value with no sign of being wrong). The checks remove it (no value is better than a wrong one).
- Solid fills give exact heights; outlined and rounded blocks and degraded dark pictures mostly return nothing.
- **Decisions**: geometry is used when it returns a value that passes the sanity checks; otherwise the end is the 60-minute default, flagged `default-60`. Outlined and rounded styles will mostly use the default until a better method is tested on real calendars. The 15-minute rounding and the 30 to 720 minute limits stay. Colour tolerance 95 (sum of channel differences) worked for JPEG-degraded solid fills.

## S4: window titles from ScreenCaptureKit

`SCShareableContent` with on-screen windows only, read on this Mac (only counts and application names were printed, never titles):

| Display | Layer 0 windows | With a title |
|---|---|---|
| 1 | 0 | 0 |
| 2 | 5 (Cisco Secure Client, Code x2, Safari, Preview) | 5 |
| 3 | 1 (ChatGPT) | 1 |

- Titles are present for every listed window with the Screen Recording permission the app already has; the call took 54 ms (the capturer already makes it).
- No remote-desktop client is installed here, so what a full-screen remote client reports could not be tested; detection stays a small list of known client application names, with the window title as an extra hint.
- **Decisions**: use the window list as designed in research R9 (layer 0, on screen, intersecting the display, largest visible area first, at most 20); the added cost is negligible.

## Consequences for the design

- `ExtractionPrompts` and the job take a separate picture size for classification (1024) and extraction (the setting); `PictureConverter` gains `jpegData(from:longEdge:)` to make the 1024 copy from the stored analysis copy.
- Research R1, R3, R7 and R9 and ADR 0014 are updated with these numbers.
- SC-008 (under 3 minutes for one display): about 26 s for the two model calls plus about 1 s for reading is well inside it, and a three-display capture is three jobs of about 30 s.

## Classification through the real pipeline (2026-09-30, task T053)

One synthetic picture of each kind was ingested with the Debug switch (`--ingest-case`) into an isolated home and classified by `qwen3.8:27b-mlx` through the queue (classification call at 1024 pixels, think off):

| Case | Kind found | Confidence | Seconds |
|---|---|---|---|
| calendar-month-web-24h | calendar_month | 1.0 | 5.9 |
| calendar-week-web-12h | calendar_week | 1.0 | 5.9 |
| calendar-day-outlook-24h | calendar_day | 0.9 | 5.6 |
| email-apple-mail-invite | email | 1.0 | 5.4 |
| chat-teams-tomorrow | chat | 1.0 | 5.5 |
| document-agenda-en | document | 0.9 | 5.4 |
| other-empty-window | other | 0.5 | 1.7 |

- 7 of 7 correct; all seven jobs finished on the first attempt; every call is stored as a `model_runs` row with `step = classify`.
- The first picture after launch also paid about 40 s for Vision's first recognition (spike S1); the model call itself took about 5.5 s, as measured in S2.
- The empty window came back as `other` with confidence 0.5, exactly at the threshold: the rule "below 0.5 counts as other" gives the same kind either way.

## Picture size sweep (2026-09-30, tasks T103 to T105)

`memorri-eval sweep-size` on the 27 synthetic cases (think off, `classify-v2`, `extract-<kind>-v4`, the app idle):

| Size | Precision | Recall | F1 | Field accuracy | Mean seconds |
|---|---|---|---|---|---|
| 1024 | 0.84 | 0.89 | 0.86 | 0.96 | 16.7 |
| 1536 | 0.82 | 0.87 | 0.84 | 0.94 | 21.2 |
| 2048 | 0.90 | 0.96 | 0.93 | 0.94 | 22.1 |
| 3072 | 0.90 | 0.96 | 0.93 | 0.94 | 22.1 |

Recommendation: 2048 (no smaller size is within 0.02 of the best F1). 2048 and 3072 are identical because the synthetic pictures are 1600 pixels wide and a size never enlarges a picture. The default stays, so T104 and T105 do not apply. See ADR 0017.
