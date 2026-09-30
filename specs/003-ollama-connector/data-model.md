# Data Model: Connect to the local model and run analysis jobs in the background

Two tables added to the local database by migration `"v2"` (spec 002 created `"v1"`), one set of settings, and a few in-memory values. Names and style follow [spec 002's data model](../002-capture-and-storage/data-model.md).

## Tables

### analysis_jobs

One unit of work for the model. In this spec only one kind exists, the model test.

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | UUID string. |
| `kind` | TEXT, not null | `test` (CHECK constraint). Later specs add kinds in their own migrations. |
| `image_id` | TEXT, nullable | The picture the job needs, from `capture_images.id`. **No foreign key**: a queued job must outlive its picture so it can fail with "picture no longer stored". Null when the job uses the built-in sample. |
| `state` | TEXT, not null | `waiting`, `running`, `finished` or `failed` (CHECK constraint). |
| `attempts` | INTEGER, not null, default 0 | Number of **failed** attempts so far (a quit during a run does not add one). |
| `not_before` | DATETIME, nullable | Earliest time the job may run (set after a transient failure); null means now. |
| `failure_reason` | TEXT, nullable | Short reason when `state` is `failed`. |
| `created_at` | DATETIME, not null | Queue order: oldest first. Indexed together with `state`. |
| `updated_at` | DATETIME, not null | Last change. |

Rules:
- At start, every `running` job becomes `waiting` with `attempts` unchanged (FR-012).
- `failed` needs `attempts` of 3, or a permanent reason (attempts may be lower).
- **Clear finished** deletes `finished` and `failed` jobs, and the `model_runs` whose `job_id` is one of them and whose `image_id` is null. **Retry failed** sets `failed` jobs to `waiting`, `attempts` to 0, `not_before` to null, `failure_reason` to null.

### model_runs

One attempt of a job.

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | UUID string. |
| `job_id` | TEXT, not null | The job. **No foreign key**, so clearing jobs does not delete runs that belong to captures. |
| `image_id` | TEXT, nullable | References `capture_images.id` with `ON DELETE CASCADE`: a capture's runs are deleted together with the capture in every kind of cleanup (clarification 1). Null for runs on the built-in sample. |
| `attempt` | INTEGER, not null | 1, 2 or 3. |
| `model` | TEXT, not null | Model name used. |
| `think` | TEXT, not null | `off`, `low`, `medium`, `high`, or `on` when the model only accepts the boolean. |
| `temperature` | REAL, not null | 0 in this spec. |
| `image_long_edge` | INTEGER, not null | Longer side in pixels of the picture sent. |
| `prompt_version` | TEXT, not null | For example `test-v1`. |
| `schema_version` | TEXT, not null | For example `test-v1`. |
| `started_at` | DATETIME, not null | |
| `duration_ms` | INTEGER, not null | Wall time of the request. |
| `outcome` | TEXT, not null | `success` or `failed` (CHECK constraint). |
| `failure_reason` | TEXT, nullable | Short reason when `outcome` is `failed`. |
| `request_json` | TEXT, not null | The request body with the picture replaced by a placeholder such as `[picture <id> 2048x857]`. Never contains picture data. |
| `raw_answer` | TEXT, nullable | The answer text as returned (and the thinking text when the server sent it). Null when nothing came back. |

Indexes: `analysis_jobs(state, created_at)`, `model_runs(image_id)`, `model_runs(job_id)`.

Migration `"v2"` creates both tables, the CHECK constraints and the indexes. Databases with migrations unknown to the app keep being refused untouched (spec 002, FR-013). The existing capture cleanup needs no change: deleting an event cascades to images and, through `image_id`, to runs.

## Job states (transitions)

| From | Event | To |
|---|---|---|
| (new) | Test the model pressed | `waiting` |
| `waiting` | oldest runnable, gate open, not paused | `running` |
| `running` | answer valid | `finished` |
| `running` | transient failure, attempts now below 3 | `waiting` (`attempts` +1, `not_before` = now + 10 s, then + 60 s) |
| `running` | transient failure, attempts now 3 | `failed` (reason) |
| `running` | permanent failure | `failed` (reason, no further attempts) |
| `running` | server became unavailable | `waiting` (attempts unchanged) |
| `running` | app quit or crashed | `waiting` at next start (attempts unchanged) |
| `failed` | Retry failed | `waiting` (attempts 0) |
| `finished`, `failed` | Clear finished | deleted |

## Settings (UserDefaults)

| Key | Type | Rules |
|---|---|---|
| `memorri.ollama.address` | String | Default `http://localhost:11434`. Only `localhost`, `127.0.0.1` and `::1` are accepted (FR-002); anything else is rejected and the previous value kept. |
| `memorri.ollama.model` | String | Empty until chosen. First use with nothing chosen: `qwen3.8:27b-mlx` if installed. |
| `memorri.ollama.think` | String | `off`, `low`, `medium` or `high`. Default `off` until the spike sets it. |
| `memorri.ollama.timeoutSeconds` | Int | 10 to 1800, default 300 until the spike sets it. Out of range is rejected and the previous value kept. |
| `memorri.analysis.paused` | Bool | Default false; survives restarts. |

## In-memory types

- **ServerStatus**: `unchecked`, `reachable(version)`, `notReachable`, `timedOut`, `noVisionModel`, `noModelChosen`, `modelMissing(name)`. With the time of the check.
- **InstalledModel**: name, `readsImages`, `thinks` (from `capabilities`).
- **ModelList**: the vision models, and the number hidden because they cannot read images.
- **QueueProgress**: counts of waiting, running, finished and failed jobs, the paused flag, and the reason the queue is holding (`Ollama not reachable`, `model not installed`, `choose a model`) or none. Drives the menu line; not stored.
- **TestResult**: valid or not, duration, and the start of the description; shown in Settings after **Test the model**; not stored (the run record has everything).
