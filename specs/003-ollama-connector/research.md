# Research: Connect to the local model and run analysis jobs in the background

Each item: Decision, Rationale, Alternatives considered. Items marked **Spike** are questions that only the real model can answer; the first tasks prove them on this Mac before extraction is built on them (same approach as spec 002). Facts about the server API were checked on 2026-09-30 against Ollama 0.34.4 running here and against its published API documentation.

## R1. The server API we use

- **Decision**: Four calls, all to the configured local address:
  - `GET /api/version` for the version shown in the status.
  - `GET /api/tags` for the installed models. On this server each entry already carries `capabilities` (for example `["completion","vision","tools","thinking"]`), so one call gives both the list and the vision and thinking check. If an entry has no `capabilities` key (older servers), ask `POST /api/show {"model": …}` for that model and read its `capabilities`.
  - `POST /api/chat` with `stream: false` for analysis: `messages` with the picture in `images` (base64), `format` set to a JSON schema, `options.temperature` 0, `think`, and no `keep_alive` (clarified: memory use is left to the server's default).
  - Nothing else. No pull, delete, embeddings or generate calls.
- **Rationale**: Minimal surface, each call observed working here. `stream: false` returns one object with `message.content`, `message.thinking`, `done_reason` and timing fields (`total_duration`, `load_duration`, `prompt_eval_duration`, `eval_count`), which go into the run record.
- **Alternatives**: streaming (progress tokens are not needed and complicate validation), the OpenAI-compatible endpoint (loses `think` and the timing fields), one `/api/show` per model (more calls for the same facts).

## R2. Keeping captured content on this Mac: one network component, loopback only

- **Decision**: A value type `LoopbackAddress` parses the setting and accepts only `http` or `https` URLs whose host is exactly `localhost`, `127.0.0.1` or `::1`, with any port, no user info, and no path other than `/`. `OllamaURLSessionTransport` is the only file in the repository that may use `URLSession`. It builds requests only from a `LoopbackAddress`, re-checks the host of every request, and refuses redirects. The no-network source scan (spec 001, FR-017) is updated to an allow-list of exactly that file, plus a test that the allow-list has one entry and that the file calls the loopback check.
- **Rationale**: Constitution principle I says Ollama is reached on localhost only. A single enforcement point with a value type that cannot hold a remote address is easier to audit than checks spread around. Rejecting redirects closes the case where a local server redirects elsewhere.
- **Alternatives**: trusting the settings field alone (a mistyped or pasted remote address would send screenshots off the Mac), resolving host names and testing the resulting address (more code, and DNS can change between check and use), running the scan over nothing (loses the guard).
- Recorded as ADR 0011.

## R3. Health check and "ready" gate

- **Decision**: `OllamaService.check()` evaluates in order and returns the first that applies: no answer from `/api/version` → `notReachable` or `timedOut` (connection refused versus no answer within 5 s); `/api/tags` lists no model with `vision` → `noVisionModel`; chosen model not in the list → `modelMissing(name)`; chosen model empty → `noModelChosen`; otherwise `reachable(version)`. The whole check has a 5 s limit. Only one check runs at a time (a second request joins the running one); the newest result is what the UI shows. The queue uses the same call as its gate: anything other than `reachable` holds the queue without using attempts, and while held it rechecks every 30 s.
- **Rationale**: One function answers the UI, the queue and the tests, so "what the user sees" and "why the queue waits" cannot disagree (SC-001, SC-007).
- **Alternatives**: separate checks for UI and queue (two places to keep consistent), polling forever when idle (waste; the queue only needs the gate while it has jobs).

## R4. Model choice

- **Decision**: The picker shows the models whose `capabilities` contain `vision`, in the server's order, and a note with the count of the others ("2 installed models are hidden because they cannot read images"). First use with nothing chosen: `qwen3.8:27b-mlx` if present, else none. The choice is stored by name; if it disappears the name is kept and a warning shows (FR-007). Thinking support for the chosen model is read from the same list.
- **Checked here**: this Mac lists six models; `qwen3.8:27b-mlx` and `qwen3.6:35b-mlx` have `vision`; the coder model, both rerankers and the embedding model do not, so the picker would show two and hide four.
- **Alternatives**: showing every model with a warning on unusable ones (invites the wrong choice), matching on model family names (fragile, the list already says what each can do).

## R5. Think level

- **Decision**: The setting is one of `off`, `low`, `medium`, `high`, default `off`, enabled only when the chosen model lists `thinking`. `off` sends `think: false`; a level is sent as the string level if the spike shows the model honours levels, and as `think: true` if it only honours the boolean (then `low`, `medium` and `high` all mean on, and the UI says so). The spike decides the default.
- **Rationale**: The API accepts a boolean or a level depending on the model; what `qwen3.8` does has to be observed.
- **Which models accept levels** is not in `capabilities` (it only says "thinking"), so it is a small built-in rule by model name (`ThinkWireValue.acceptsLevels(modelName:)`), written from the spike; the default is boolean only.
- **Spike S3** (part of S2 below): compare `think: false` with the levels the model accepts.

## R6. Request timeout

- **Decision**: Range 10 to 1800 seconds, default 300 until the spike sets it. The transport sets the URLSession request timeout to the setting and the resource timeout to the setting plus 10 s, so a request that has produced nothing by then is abandoned and counts as a temporary failure. With `stream: false` the server sends nothing until the answer is complete, so this is also the limit for the whole answer.
- **Alternatives**: a streaming idle timeout (would let slow but progressing answers finish, at the cost of streaming code; revisit only if the spike shows long legitimate answers).

## R7. Durable serial queue

- **Decision**: Jobs live in the local database (table `analysis_jobs`, migration "v2"), so nothing is lost on quit or crash. An `AnalysisQueue` actor owns one long-lived loop: wait until not paused and the server is ready; take the oldest waiting job whose `not_before` has passed; run it through a handler; record the outcome. Because one loop does one job at a time, two jobs can never run together. A job's `attempts` counts failed attempts only, so a job that was running at quit is put back to `waiting` at start with `attempts` unchanged (SC-006).
  - Outcomes from the handler: `success`, `transient(reason)` (timeout, lost connection, server error, invalid or non-matching answer), `permanent(reason)` (picture no longer stored, request rejected as invalid), `serverUnavailable` (the gate closed mid-job: back to `waiting`, no attempt used).
  - Transient: `attempts += 1`; at 3 the job is `failed` with the reason; otherwise `waiting` with `not_before` = now + 10 s after the first failure, now + 60 s after the second.
  - Pause is one flag in settings (`memorri.analysis.paused`), checked before each job; the running job finishes (FR-016, SC-011).
  - Progress is a small value (`QueueProgress`) pushed to the app whenever it changes.
- **Rationale**: A single loop gives the serial guarantee by construction. Persisting in the existing database reuses migrations, transactions and the start-up handling from spec 002.
- **Alternatives**: `OperationQueue` with max concurrency 1 (no persistence, harder to test), a separate file or store for jobs (a second persistence mechanism), counting attempts at start (a quit would cost an attempt, which the spec forbids).
- Recorded as ADR 0012.

## R8. Retry for invalid answers

- **Decision**: An answer that is not valid JSON, or does not match the schema, is a transient failure. Because the temperature is near zero, resending the same request would usually give the same answer, so attempts 2 and 3 of the same job add a short repair note to the prompt that names the problem ("Your previous answer was not valid for this schema: …. Answer with JSON only."). Whether that helps, and whether the native `format` makes it unnecessary, is measured by the spike (S2) and the note is dropped if it does not help.
- **Alternatives**: retrying unchanged (cheap but often pointless), raising the temperature on retries (breaks the reproducibility principle in ADR 0005).

## R9. Run records and cleanup

- **Decision**: Every attempt writes a `model_runs` row: model, think level, picture size, prompt version, schema version, start time, duration, attempt, outcome, reason, temperature, the raw answer, and the request as JSON with the picture replaced by a placeholder (`[picture <id> <w>x<h>]`). `model_runs.image_id` references `capture_images` with `ON DELETE CASCADE`, so the existing cleanup (spec 002) removes a capture's runs together with it with no new code path (clarified: raw answers live and expire with their capture). Runs with no capture (from the built-in sample) have a null `image_id` and are removed by **Clear finished** together with their job. Jobs themselves do not reference pictures by foreign key: a queued job whose picture is gone must survive long enough to fail with "picture no longer stored".
- **Rationale**: Rides on cascade deletes already tested in spec 002; matches ADR 0005's "record raw request and response" without storing megabytes of base64.

## R10. The built-in test picture

- **Decision**: A synthetic picture drawn in code with Core Graphics and Core Text (a small calendar-like grid with known texts such as "Team sync" and "10:00"). It needs no asset file, contains nothing from the user's sessions, has known correct content, and can be drawn at any size. It is the picture of **Test the model** when no capture exists and the picture of the spike.
- **Alternatives**: a bundled PNG (a binary in git, fixed size), a real screenshot (forbidden in the repository, and sensitive).

## R11. What "Test the model" asks

- **Decision**: A fixed prompt, version `test-v1`, and a small schema, version `test-v1`: `{ "description": string, "contains_text": boolean, "text_sample": string }`, all required. The result line in Settings shows: valid or not, the time, and the first characters of `description`. It is not extraction; spec 004 adds real prompts and schemas.

## R12. Menu line and its texts

- **Decision**: A pure function turns `QueueProgress` into the exact texts of FR-016 and is unit-tested: precedence paused, then waiting with a reason, then running, then waiting, then idle; failures are appended (`Analysis: 2 waiting, 1 failed`). The reason strings are `Ollama not reachable`, `model not installed`, `choose a model`. The app updates the line when progress changes and a 5 s tick keeps the times current.

## R13. Testing without the real model

- **Decision**: Unit tests use a fake `OllamaTransport` (scripted answers, delays, failures), a fake clock and the real database in a temporary directory. The real URLSession transport is tested with a local `URLProtocol` stub for requests and with a test that proves non-loopback addresses never produce a request. The real model is exercised by the spike and by quickstart scenarios.

## R14. Spike S1: the server facts on this Mac (done while planning)

- **Result (2026-09-30)**: Ollama 0.34.4. `GET /api/tags` returns `capabilities` per model. `POST /api/show` for `qwen3.8:27b-mlx` returns `capabilities: ["completion","vision","tools","thinking"]`, `details.parameter_size` 27.8B, quantization nvfp4, context length under `model_info["qwen3_5.context_length"]`. `GET /api/ps` shows nothing loaded at rest. The documentation confirms `format` takes `json` or a JSON schema, `think` takes a boolean or `low`, `medium`, `high`, `max` depending on the model, `keep_alive` defaults to 5 minutes, and a non-streaming answer carries `total_duration`, `load_duration`, `prompt_eval_duration` and `eval_count`.

## R15. Spike S2: does the model honour a JSON schema with a picture attached, and what does it cost?

- **Question**: With the built-in test picture attached and `format` set to the test schema, how often does `qwen3.8:27b-mlx` return an answer that parses and matches the schema exactly, and is the content right?
- **Design**: A throwaway Swift script (not committed) draws the test picture at 1024, 1536, 2048, 3072 and 4096 pixels on the longer side, and for each size calls `/api/chat` 5 times with `think: false` and 5 times with thinking on (the level the model accepts), `temperature 0`. It also runs the same matrix once without `format`, with the schema only described in the prompt, to see whether the fallback is needed. The first call of each session is labelled cold (model load). For each call it records the valid-answer rate, whether `description` mentions the known texts, and `total_duration`, `load_duration`, `prompt_eval_duration`, `eval_count`. Results are summarised as a table (valid rate, median and maximum time per size and setting) in `spike-report.md`.
- **Decisions it feeds**: native `format` versus the fallback (ADR 0005, recorded in ADR 0013), the default timeout, the default think level, the default picture size, and whether the repair note in R8 helps.
- **Privacy**: only the synthetic picture is used; nothing from the user's sessions.
- **Time**: about 50 calls with thinking off and on, plus a fallback run; expect tens of minutes. It runs in the background while other work continues.
