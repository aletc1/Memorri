# Quickstart: validating spec 003

How to see that the feature works end to end. Most steps can be driven from a terminal on the developer Mac (Accessibility and Screen Recording are granted to the terminal or editor, as in specs 001 and 002). Looking at stored pictures shows your own screen, so do it only on a prepared test screen.

## Prerequisites

- Specs 001 and 002 merged and working (capture stores analysis copies; permission granted).
- Ollama running locally with `qwen3.8:27b-mlx` installed: `curl -s localhost:11434/api/version` answers.
- Build and run: `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build && open .build/xcode/Build/Products/Debug/Memorri.app`.
- `APP=.build/xcode/Build/Products/Debug/Memorri.app`, `DB="$HOME/Library/Application Support/Memorri/memorri.sqlite"`.
- Watch the log: `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri"'` (full path; zsh has its own `log`). Redirected streams buffer, so use `/usr/bin/log show --last 1m …` for checks in scripts.
- The fake server for failure cases: `python3 scripts/fake-ollama.py --port 11999 --mode ok|invalid|slow|error|flaky` (added by this spec). It answers `/api/version`, `/api/tags` (one vision model) and `/api/chat` with the chosen behaviour, so the real model is not touched.

## Build and unit tests

`swift test --package-path Packages/MemorriCore` passes, including the updated no-network scan (exactly one allowed file).

## Spike S2: structured answers with pictures (before anything else is built on it)

| Step | Expected |
|---|---|
| Run the spike script from the tasks (synthetic test picture at 1024, 1536, 2048, 3072, 4096; thinking off and on; 5 runs each; then the same without `format`). | A results table is written to `spike-report.md`: valid-answer rate, content correct, median and maximum time per size and setting, cold versus warm. |
| Read the decision section. | One recorded decision (native `format` or fallback), a default timeout, a default think level, a default picture size; ADR 0013 written; ADR 0005 superseded only if the decision changed. |

## Scenario 1: connection and status (User Story 1)

| Step | Expected |
|---|---|
| Open Settings, Ollama, with the real server running. | `Reachable, Ollama 0.34.4` (or the current version) within 5 s. Log: `check status=reachable`. |
| Apply `http://localhost:11999` (nothing listening). | Status `Not reachable. Start Ollama and try again.` within 5 s. |
| Start the fake server in `slow` mode on 11999 that never answers `/api/version`. | `No answer within 5 seconds.` |
| Apply `http://example.com`, `http://192.168.1.5:11434`, `http://10.0.0.2`, `http://localhost.evil.com`. | Each is rejected with the local-only message and the previous address stays (SC-003). Apply `http://127.0.0.1:11434`: accepted. |
| `lsof -i -a -p $(pgrep -x Memorri)` while checking | Connections only to localhost ports. |

## Scenario 2: model picker (User Story 2)

| Step | Expected |
|---|---|
| Delete the `memorri.ollama.model` default and open the section. | The picker lists the two vision models installed here, `qwen3.8:27b-mlx` is selected, and the note says `4 installed models are hidden because they cannot read images.` (the numbers follow what is installed). |
| Point at the fake server with no `capabilities` on its models and with a model without `vision`. | The non-vision model is not listed; with no vision model at all the status says so. |
| Choose a model the server then "removes" (fake server drops it). | Warning `The chosen model … is no longer installed.`; the choice is kept. |

## Scenario 3: test the model (User Stories 3 and 4)

| Step | Expected |
|---|---|
| Click **Test the model** with the real server and a stored capture. | `Using the newest capture.` then a result line with a valid answer and its time. `sqlite3 "$DB" "select outcome, attempt, duration_ms from model_runs order by started_at desc limit 1;"` gives `success|1|…`; `request_json` contains `[picture`, never base64 data. |
| Clean all captures, click it again. | `Using the built-in sample picture.`; the run has a null `image_id`. |
| Delete a capture that has runs (Storage, delete all captures). | `select count(*) from model_runs where image_id is not null;` is 0 (runs go with their capture). |

## Scenario 4: the queue (User Stories 4 and 5)

| Step | Expected |
|---|---|
| With the fake server in `slow` mode (each answer 5 s), press **Test the model** 5 times. | Menu line `Analysing 1 of 5…`, counting down. The log shows `job started` only after the previous `job finished` (SC-005); order is oldest first. |
| While one runs, quit the app (`pkill -x Memorri`) and relaunch. | `recovered running=1`; the job is waiting again and `select attempts from analysis_jobs` shows 0 for it (SC-006). |
| Fake server in `invalid` mode, one job. | Three runs with waits of about 10 s and 60 s, then `failed` with `invalid answer` (SC-008). Menu `Analysis: idle, 1 failed`. |
| **Retry failed**. | The job is waiting with 0 attempts. |
| Stop the fake server with jobs waiting. | Within 35 s the menu says `Analysis waiting: Ollama not reachable` and no job is failed; restart it and the queue resumes within 35 s by itself (SC-007). |
| Choose **Pause analysis** during a job, relaunch. | The running job finishes, nothing new starts, `Analysis paused`; still paused after relaunch; **Resume analysis** continues within 5 s (SC-011). |
| Open the menu and Settings during a job. | Both respond at once (SC-009). |
| **Clear finished**. | Finished and failed jobs are gone; waiting and running ones stay. |

## Scenario 5: tuning (User Story 6)

| Step | Expected |
|---|---|
| Choose a model that supports thinking and set a level. | `think` in the next run record shows the level (or `on`). Disabled with a note for a model without `thinking`. |
| Timeout 5: rejected with `Enter a value between 10 and 1800.` Timeout 10 with the fake `slow` mode (15 s answer). | The request is abandoned at about 10 s and counts as a transient failure. |
| Change the think level during a running job. | The running job keeps its values; the next job uses the new ones. |

## No network and no leftovers

`lsof -i -a -p $(pgrep -x Memorri)` shows only localhost. The source scan test passes with exactly one file allowed to use `URLSession`. No screenshot or model output from real sessions is committed.

### Observed on the developer Mac (2026-09-30, Ollama 0.34.4, `qwen3.8:27b-mlx`)

Driven from a terminal with System Events for clicks and the menu, `sqlite3` for records and `/usr/bin/log show --info` for the log. Scenarios 3 to 5 ran in a separate data folder (`CFFIXED_USER_HOME`) except the stored-capture step, which used the real capture folder read-only (only outcome, timing and request text were read, never the answer).

| Scenario | Result |
|---|---|
| Spike S2 | See `spike-report.md` and ADR 0013: native `format` 50/50 valid; fallback 8/30; HEIC rejected by the server; defaults think off, timeout 300 s, picture 2048. |
| 1 Connection (SC-001) | 10/10 trials showed the right status; real checks 7 to 35 ms; a silent server gave `timedOut` at 5.008 s; `lsof` showed localhost only. |
| 2 Model picker (SC-002) | Picker showed the chosen vision model and hid 4 others (note shown); list timing not measured; the model was chosen at launch without opening Settings; `gone:1b` showed the orange "no longer installed" warning; `--no-vision` showed "Ollama is running but no installed model can read images." |
| 3 Test the model (SC-010) | Newest capture: `success\|1\|15538`, `think=off`, `image_long_edge=2048`, `[picture …]` placeholder, no base64. Built-in sample (empty data folder): `success\|1\|14710`, `image_id` null, `[picture sample 2048x1152]`, result line `Answer valid in 14.7 s: "A weekly calendar view from Monday to Friday with a blue eve…"`. Deleting captures with runs is covered by `StorageDatabaseTests` (cascade), not repeated by hand because it would delete real captures. |
| 4 Queue (SC-005 to SC-009, SC-011) | 5 jobs in `slow` mode: each `job started` came 7 to 12 ms after the previous `job finished`, oldest first (SC-005, 10 jobs are checked by `AnalysisQueueTests`). Kill -9 during a job: `recovered running=1`, attempts 0, then finished (SC-006). `invalid` mode: attempts at 12:21:53, 12:22:03 (10.0 s), 12:23:03 (60.2 s), then `failed` with `invalid answer`, 3 attempts (SC-008, one live case, more in unit tests). Retry failed gave waiting with 0 attempts. Server stopped: `queue holding reason=Ollama not reachable` within 1 s, nothing failed; restarted: resumed after 21 s (SC-007). Pause during a job: the running job finished, nothing new started, menu `Analysis paused`, still paused after relaunch, running 0.34 s after Resume (SC-011). Menu and Settings answered while jobs ran (clicks and reads succeeded; not timed with a stopwatch, SC-009). Clear finished removed all jobs and their sample runs. |
| 5 Tuning | Model with thinking and level High: run `think=on` (qwen takes on or off only), Settings shows the on/off note. A model without thinking: picker disabled with the note. Timeout 10 against a 15 s answer: abandoned at 10.005 s as `timed out`, job waiting with 1 failed attempt. Changes between and during attempts are unit-tested. |

Not driven by hand: typing a non-local address, or a timeout of 5, into the fields (automation cannot fill SwiftUI text fields); both rules are unit-tested (`OllamaSettingsTests`, `LoopbackAddressTests`) and SC-003 rests on those tests. Observed by hand only: SC-001, SC-005 (5 of 10 jobs), SC-006, SC-007, SC-008 (1 of 5 cases), SC-009, SC-011.
