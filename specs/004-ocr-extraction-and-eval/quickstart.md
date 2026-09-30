# Quickstart: validating spec 004

How to see that the feature works end to end. Most steps run from a terminal on the developer Mac. **Never look at real captures**: the scenarios use drawn pictures (`memorri-eval generate-synthetic`, the debug `--ingest-picture` switch) so nothing from the user's sessions is shown or stored by these checks.

## Prerequisites

- Specs 001 to 003 merged and working; Ollama running with `qwen3.8:27b-mlx`.
- `APP=.build/xcode/Build/Products/Debug/Memorri.app`, `DB="$HOME/Library/Application Support/Memorri/memorri.sqlite"`. To keep the real data untouched, run the app with `CFFIXED_USER_HOME=/tmp/memorri-home` (preferences are still shared: restore the address and model afterwards).
- Log: `/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.aletc1.memorri"'`.
- Pause the app's analysis or quit the app before running `memorri-eval` (it refuses otherwise).

## Build and unit tests

`swift test --package-path Packages/MemorriCore` passes; the no-network scan still allows exactly one file.

## Spikes (before the rest is built on them)

| Spike | Step | Expected |
|---|---|---|
| S1 text recognition | Run the recogniser over the drawn pictures at native size and degraded (75%, JPEG 0.4), language correction on and off. | Report: exact-text rate, box overlap, warm seconds per picture; decision on language correction (feeds SC-003). |
| S2 model with lines | Send picture plus numbered lines for each kind; vary line detail and message order; repeat call 2 right after call 1. | Report: valid-answer rate, valid-citation rate, seconds of the second call; decision in ADR 0014. |
| S3 block geometry | Run `BlockGeometry` on drawn week views in five styles. | Report: how often a value comes back and the error in minutes per style. |
| S4 window titles | Read titles for a browser, Mail, Calendar and any remote-desktop client available. | Report: titles and application names present or blank; added milliseconds in the capture step. |

## Scenario 1: the harness (User Story 1)

| Step | Expected |
|---|---|
| `memorri-eval generate-synthetic`, then again, then `git status`. | About 26 cases under `eval/golden/synthetic/`; the second run changes nothing (same bytes). |
| `memorri-eval run` with the app's queue busy (`open` a slow fake job first). | Refused with the pause message; nothing scored; exit 2. With `--allow-busy` it runs and the report says so. |
| `memorri-eval run --out eval/out/a.json`. | Precision, recall, field accuracy, classification and tag accuracy overall, per kind and per case; missed and unexpected listed (SC-001, SC-002). |
| Edit one expected finding's end time (+10 min; a start more than 5 minutes off no longer matches, so it would show as a miss instead), `run --replay eval/out/a.json --out eval/out/b.json`, `compare a b`. | That case's field accuracy falls; the changed case is named; no model call was made (SC-009). |
| Stop Ollama, run again. | `Not reachable` status, nothing scored, exit 2. |

## Scenario 2: reading and classifying a picture (User Stories 2 and 4)

| Step | Expected |
|---|---|
| With `CFFIXED_USER_HOME`, launch the app with `--ingest-picture eval/golden/synthetic/<week-case>/screenshot.png`. | The picture is stored and queued; log shows `read … lines=<n>`, `classify … kind=calendar_week`. |
| `sqlite3 "$DB" "select count(*) from ocr_lines; select screen_kind from image_analysis;"`. | Lines match the case (95% exact, SC-003); kind `calendar_week`. |
| Ingest the same picture again (new capture) and reanalyse the first. | No duplicate lines for a picture (`select image_id, n, count(*) … having count(*) > 1` is empty). |
| Ingest a text-free picture. | `ocr_reads` has a row with `line_count = 0`; analysis finishes with 0 findings. |
| Delete all captures (Storage) in the isolated home. | `ocr_lines`, `image_analysis`, `findings`, `capture_tags`, `capture_windows`, `image_context` and `model_runs` with a picture are empty. |

## Scenario 3: findings, dates and durations (User Stories 3, 5 and 6)

| Step | Expected |
|---|---|
| Ingest the week-view case with a 90-minute block, a 30-minute block and a text-only meeting. | Three appointments; ends 90 min, 30 min and 60 min after their starts; `provenance_json` shows `inferred` with `block-height`, `block-height`, `default-60`. |
| Ingest the email case "Anna needs the report by Friday" (captured on a Tuesday). | A task for Anna with the Friday due date and rule `end-of-week` or `weekday-only`. |
| Ingest the case captured at 23:40 UTC with a context zone of New York and Mac zone Madrid. | "Tomorrow" resolves against the New York date; `timezone` is `America/New_York`. |
| Use `scripts/fake-ollama.py --mode extract-bad-citation`. | The finding citing a line that does not exist is discarded and listed in `discarded_json`; the others stay (SC-004). `--mode invalid` retries as in spec 003. |
| `select count(*) from findings where cited_lines_json = '[]'`. | 0. |

## Scenario 4: contexts and tags (User Stories 7 and 8)

| Step | Expected |
|---|---|
| Insert two contexts with different hints and zones (Settings → Analysis, or `sqlite3` in the isolated home). Ingest pictures with `--ingest-windows` naming each. | Each is assigned to its context with `matched_json`; a picture that matches both equally is `none` with a tie recorded (SC-007). |
| Change one picture's context to the other in Settings → Analysis, press **Reanalyse**. | The user's choice stays (`source = user`). |
| Delete a context. | Its pictures show `Unassigned`; their findings are intact. |
| `select key, value, source from capture_tags where image_id = …`. | Application, platform look, clock style, language and domain tags as drawn; none with a high confidence when wrong more than once in 20 cases (SC-012); every finding's `tags_json` equals the picture's tags. |

## Scenario 5: automatic analysis and the queue (spec 003 meets 004)

| Step | Expected |
|---|---|
| With automatic analysis on, capture with the hotkey on a prepared test screen. | One `analyse` job per display appears and runs one at a time; the menu counts them; analysis finishes in under 3 minutes for one display (SC-008) and Settings and the menu respond while it runs. |
| Turn the switch off and capture again. | No job is queued. |
| **Analyse stored captures**. | Every picture without analysis and without a waiting job is queued once, oldest first; pressing it again queues none. |
| Pause during a job, relaunch. | As in spec 003: the running job finishes, nothing new starts, still paused after relaunch. |
| Kill the app during the extraction step, relaunch. | `recovered running=1`; the job resumes; the read step is not repeated (`ocr_reads.read_at` unchanged). |

## Scenario 6: size study (User Story 9)

| Step | Expected |
|---|---|
| `memorri-eval sweep-size`. | A table of precision, recall, field accuracy and seconds per size for at least 1024, 1536, 2048 and 3072, and a recommended default with the reason (SC-010). |
| Record the decision (ADR 0017) and, if it changed, check `defaults delete com.aletc1.memorri memorri.storage.modelLongEdge` shows the new default in Settings → Storage while a value set by the user is kept. | The setting behaves as stated. |

## No network and no leftovers

`lsof -i -a -p $(pgrep -x Memorri)` and the same for `memorri-eval` during a run show only localhost. The source scan passes. `git status` shows only synthetic golden cases; no screenshot, capture or model answer from a real session is committed.
