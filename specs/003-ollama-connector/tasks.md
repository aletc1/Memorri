---

description: "Task list for spec 003: connect to the local model and run analysis jobs in the background"
---

# Tasks: Connect to the local model and run analysis jobs in the background

**Input**: Design documents from `/specs/003-ollama-connector/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. The model's behaviour is proven by the spike (Phase 1) and by the quickstart scenarios; everything else is tested against fakes.

**Organization**: Grouped by user story. User Story 3 (the spike) is done first, in Phase 1, because its results set the defaults and the way structured answers are requested. Paths follow the layout in plan.md (`App/`, `Packages/MemorriCore/`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 connection and status, US2 model picker, US3 spike (Phase 1, no label), US4 serial queue with retries, US5 menu progress and pause, US6 tuning
- Commands assume the repository root as the working directory.

## Phase 1: Setup and spikes

**Purpose**: Prove on the real model what only it can answer, and prepare the stand-in server, before anything is built on the answers (lesson from specs 001 and 002). The spike (T001 to T003) fulfils User Story 3. T002 takes tens of minutes, so start it first and keep working while it runs; nothing in Phase 2 depends on its result except the default values in T009.

- [x] T001 Spike S2, part 1: write a throwaway Swift script in the scratchpad (not committed) that draws the synthetic test picture with Core Graphics and Core Text (a small calendar-like grid containing the known texts "Team sync" and "10:00") at a given longer side, sends it to `POST http://localhost:11434/api/chat` (`stream: false`, `options.temperature` 0, no `keep_alive`) with the test prompt and the test schema from `specs/003-ollama-connector/contracts/core-interfaces.md` (`{ description: string, contains_text: boolean, text_sample: string }`, all required) in `format`, and prints per call: whether the answer parses and matches the schema exactly, whether `description` mentions a known text, `total_duration`, `load_duration`, `prompt_eval_duration`, `eval_count` and the thinking text length. The script takes the picture size, the `think` value, and a mode (`native` uses `format`; `fallback` describes the schema in the prompt and sends no `format`). Also make it try the `think` values `false`, `true`, `"low"`, `"medium"` and `"high"` once each to learn which ones the model accepts
- [ ] T002 Spike S2, part 2: run the matrix against `qwen3.8:27b-mlx` with the script from T001: picture sizes 1024, 1536, 2048, 3072 and 4096 on the longer side, each with thinking off and with thinking on (the value the model accepts), 5 runs per combination in `native` mode, then one pass of the whole matrix in `fallback` mode, then one extra pass where attempts 2 and 3 after an invalid answer add the repair note from `research.md` R8 (only if any invalid answer occurred). Label the first call of the session as cold. Run it in the background with output to a file in the scratchpad (`run_in_background`), using only the synthetic picture, and keep the raw results
- [ ] T003 Spike S2, part 3: write `specs/003-ollama-connector/spike-report.md` from the results of T002: a table per mode with valid-answer rate, content-correct rate, median and maximum time per picture size and thinking setting (cold versus warm noted), the accepted `think` values, whether the repair note helped, and one decision section that records: native `format` or fallback, the default timeout, the default think level, the default picture size, and which `think` wire values are used for each level, including the rule for which model names accept levels (used by `ThinkWireValue.acceptsLevels(modelName:)`). Write ADR `docs/architecture/decisions/0013-model-request-defaults-from-the-spike.md` (copied from `0000-template.md`, Status Proposed) with those decisions; supersede ADR 0005 with it only if the decision changed (never edit an accepted ADR's decision). Update the starting guesses in `spec.md` Assumptions, `data-model.md`, `contracts/ui-contract.md` and `research.md` (R5, R6, R8) so they state the measured defaults
- [x] T004 [P] Write the stand-in server `scripts/fake-ollama.py` (Python standard library only, `python3 scripts/fake-ollama.py --port 11999 --mode ok|invalid|slow|error|flaky`): `GET /api/version` answers `{"version":"0.0.0-fake"}`; `GET /api/tags` lists one vision model `fake-vision:1b` with `capabilities` `["completion","vision"]` and one text-only model; `POST /api/chat` answers by mode: `ok` returns a valid answer for the test schema, `invalid` returns text that is not valid JSON, `slow` waits 5 s (and `--delay <seconds>` overrides) before a valid answer, `error` returns HTTP 500, `flaky` fails with HTTP 500 on odd calls and answers on even ones; it prints one line per request with a timestamp and the path so the quickstart can check ordering. Smoke-test each mode with `curl`

**Checkpoint**: `spike-report.md` has the measured defaults and the decision; ADR 0013 exists; the fake server answers in every mode.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: The address rule, the network boundary, the client, the settings, the database tables and the picture lookups that every user story needs. Tests first, then code. Tasks that edit `Fakes.swift` are not marked parallel.

- [x] T005 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/LoopbackAddressTests.swift`: accepted: `http://localhost:11434`, `http://127.0.0.1:8080`, `http://[::1]:11434`, `https://localhost`, `http://localhost` (default port kept as typed), text with surrounding spaces; rejected (`init?` returns nil): `http://example.com`, `http://192.168.1.5:11434`, `http://10.0.0.2`, `http://8.8.8.8`, `http://localhost.evil.com`, `http://127.0.0.1.evil.com`, `http://user@evil.com@localhost`, `http://user:pass@localhost`, `ftp://localhost`, `localhost:11434` (no scheme), `http://localhost/api`, empty text; `LoopbackAddress.standard.text` is `http://localhost:11434`; `url` round-trips `text`
- [x] T006 Implement `LoopbackAddress` in `Packages/MemorriCore/Sources/MemorriCore/Inference/LoopbackAddress.swift` per `contracts/core-interfaces.md` (scheme `http` or `https`, host exactly `localhost`, `127.0.0.1` or `::1`, no user info, path empty or `/`); the tests pass
- [x] T007 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/JSONValueTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/SchemaValidatorTests.swift`: `JSONValue` decodes and encodes objects, arrays, strings, integers, doubles, booleans and null, and keeps an integer as `.int`; `SchemaValidator.validate` accepts an exact match of the test schema (`{ description: string, contains_text: boolean, text_sample: string }`, all required, `additionalProperties` false) and rejects, with the matching error: text that is not JSON (`.notJSON`), a missing required key, a wrong type (`contains_text` as a string), an extra key, a value outside an `enum`, an array item of the wrong type, and a JSON value that is not an object when the schema says object (all `.mismatch` with a short message naming the path)
- [x] T008 Implement `JSONValue` in `Packages/MemorriCore/Sources/MemorriCore/Inference/JSONValue.swift` and `SchemaValidator` in `Packages/MemorriCore/Sources/MemorriCore/Inference/SchemaValidator.swift` per the contract (subset: `type` object, string, boolean, integer, number, array; `properties`, `required`, `enum`, `items`, `additionalProperties` false); the tests pass
- [ ] T009 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaSettingsTests.swift` with the fake `SettingsStore`: defaults are address `http://localhost:11434`, no model, think and timeout as recorded in `spike-report.md` (starting guesses: `off` and 300), analysis paused false; `setAddress` accepts `http://127.0.0.1:8080` and rejects `http://example.com` returning false and keeping the previous value; `setTimeoutSeconds` accepts 10 and 1800 and rejects 9 and 1801 keeping the previous value; `setThink` and `setModel(nil)` round-trip; `setAnalysisPaused` round-trips; keys are exactly `memorri.ollama.address`, `memorri.ollama.model`, `memorri.ollama.think`, `memorri.ollama.timeoutSeconds`, `memorri.analysis.paused`; a stored non-local address or out-of-range timeout falls back to the default
- [ ] T010 Implement `OllamaSettings` and `ThinkSetting` in `Packages/MemorriCore/Sources/MemorriCore/Settings/OllamaSettings.swift` per the contract; the tests pass
- [x] T011 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaClientTests.swift` using a new `FakeOllamaTransport` added to `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift` (scripted responses per path, records the requests, optional delay and error): `version()` reads `/api/version`; `models()` reads `capabilities` from `/api/tags` (vision and thinking flags) and calls `/api/show` only for entries without `capabilities`; `chat` sends `POST /api/chat` with `stream` false, `format` equal to the schema, `options.temperature` 0, the picture as base64 in `messages[0].images`, no `keep_alive`, and `think` as the wire value from `ThinkWireValue.make(setting:modelThinks:acceptsLevels:)` (`off` false; a level as a string when the model accepts levels, else `true`; always `false` when the model does not think) and `ThinkWireValue.acceptsLevels(modelName:)` from the spike rule; with `useNativeFormat` false the body has no `format` and the schema is described in the prompt text; the response maps `message.content`, `message.thinking`, `done_reason` and the four duration or count fields; `requestJSON(for:)` contains the placeholder and never the base64 text; HTTP 500 and 400, malformed JSON, a timeout, an unreachable server and a redirect refusal map to distinct `OllamaClientError` cases (`serverError(code)`, `requestRejected`, `badResponse`, `timedOut`, `unreachable`)
- [x] T012 Implement `OllamaTransport` (protocol, `OllamaHTTPRequest`, `OllamaHTTPResponse`, `OllamaTransportError`) in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaTransport.swift`, `OllamaClient`, `ChatRequest`, `ChatResponse`, `InstalledModel`, `ThinkWireValue` and `OllamaClientError` in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaClient.swift`; the tests pass
- [x] T013 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaURLSessionTransportTests.swift` (a `URLProtocol` stub for requests, a real closed local port for refusal): a request goes only to the loopback address it was built from; a response is returned with status and body; a redirect (302 to another host) fails with `redirectRefused`; no answer within the timeout fails with `timedOut`; connecting to a closed local port fails with `unreachable`; the transport cannot be built from a non-loopback address (the initializer takes a `LoopbackAddress`). Also update `Packages/MemorriCore/Tests/MemorriCoreTests/NoNetworkTests.swift` first: replace the blanket scan with an allow-list of exactly one file, `OllamaURLSessionTransport.swift`, that may contain `URLSession`; keep `NWConnection`, `import Network` and `CFNetwork` forbidden everywhere; add tests that the allow-list has exactly one entry, that the scanner still finds a planted `URLSession` in any other file, and that the allowed file contains a call to the loopback check; keep the test that `project.yml` declares no network entitlement
- [x] T014 Implement `OllamaURLSessionTransport` in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaURLSessionTransport.swift` (URLSession built only from a `LoopbackAddress`, request timeout from the request and resource timeout plus 10 s, re-check of the host of every request, redirect refused through a session delegate, errors mapped to `OllamaTransportError`); the tests pass, including the updated no-network scan
- [x] T015 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v2"` (extend the existing suite): table `analysis_jobs` with `id` TEXT primary key, `kind` TEXT not null with no CHECK constraint (validated in code, so a later spec can add a kind without a table rebuild), `image_id` TEXT nullable with no foreign key, `state` TEXT not null CHECK (`waiting`, `running`, `finished` or `failed`), `attempts` INTEGER not null default 0, `not_before` DATETIME nullable, `failure_reason` TEXT nullable, `created_at` and `updated_at` DATETIME not null; table `model_runs` with `id` TEXT primary key, `job_id` TEXT not null with no foreign key, `image_id` TEXT nullable references `capture_images.id` ON DELETE CASCADE, `attempt` INTEGER not null, `model`, `think`, `prompt_version`, `schema_version` TEXT not null, `temperature` REAL not null, `image_long_edge` INTEGER not null, `started_at` DATETIME not null, `duration_ms` INTEGER not null, `outcome` TEXT not null CHECK (`success` or `failed`), `failure_reason` TEXT nullable, `request_json` TEXT not null, `raw_answer` TEXT nullable; indexes on `analysis_jobs(state, created_at)`, `model_runs(image_id)` and `model_runs(job_id)`; inserting a `state` of `done` or an `outcome` of `ok` fails, while any `kind` text is stored; deleting a capture event cascades to its images and, through `image_id`, to that capture's runs, while an image-less run and every job remain; a database that only has `"v1"` (create it with the v1 migration alone, insert a capture, then open it with `StorageDatabase.open`) gains the v2 tables without losing the capture; a database with an unknown later migration is still refused untouched
- [x] T016 Implement migration `"v2"` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift` exactly as specified in the previous task, and `AnalysisJobRecord` and `ModelRunRecord` (GRDB records with explicit snake_case coding keys) in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisJobStore.swift`; the tests pass
- [ ] T017 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisStoreTests.swift` (real database in a temporary directory): `enqueue` and `nextRunnable` return the oldest waiting job first and skip a job whose `not_before` is in the future; `nextWakeUp` returns the earliest future `not_before`; `markRunning`, `markFinished`, `markWaiting(failedAttempts:notBefore:)` and `markFailed(failedAttempts:reason:)` change state, attempts and reason as in the data-model transition table; `recoverRunningJobs` turns every `running` job into `waiting` with `attempts` unchanged; `record(run:)` stores a run; `counts` and `recentFailures(limit:)` are correct; `retryFailed` sets failed jobs to `waiting` with attempts 0, `not_before` nil and no reason and returns how many; `clearFinished` deletes finished and failed jobs and only the runs of those jobs whose `image_id` is nil, leaving runs that belong to captures and waiting or running jobs
- [ ] T018 Implement `AnalysisJobStoring`, `AnalysisStore` and `JobCounts` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisJobStore.swift` per the contract; the tests pass
- [ ] T019 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StoredPictureProviderTests.swift` and extend `Packages/MemorriCore/Tests/MemorriCoreTests/CaptureStoreTests.swift`: `CaptureStore.image(id:)` returns the record or nil; `CaptureStore.newestImageID()` returns the image of the newest event that has images, or nil; `StoredPictureProvider.analysisPicture(imageID:)` reads the analysis copy file of a stored image and returns its bytes with `longEdge`, `width` and `height` from the record, and returns nil when the record is gone, the file is missing or the record is marked missing
- [ ] T020 Implement `CaptureStore.image(id:)`, `CaptureStore.newestImageID()` in `Packages/MemorriCore/Sources/MemorriCore/Storage/CaptureStore.swift` and `AnalysisPictureProviding` with `StoredPictureProvider` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/StoredPictureProvider.swift`; the tests pass

**Checkpoint**: `swift test --package-path Packages/MemorriCore` passes, including the updated no-network scan, and the app builds.

---

## Phase 3: User Story 1 - Connect to the local model server and see that it works (Priority: P1) 🎯 MVP

**Goal**: the Ollama section shows the address and an accurate, fast status from a real check.

- [ ] T021 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaServiceTests.swift` with `FakeOllamaTransport`, a fake clock and the fake settings: `check()` returns `.notReachable` when the connection is refused and `.timedOut` when no answer comes within 5 s (`OllamaService.checkTimeout`); then `.noVisionModel` when no model has `vision`; `.noModelChosen` when no model is chosen; `.modelMissing(name)` when the chosen model is not listed; otherwise `.reachable(version:)`, evaluated in that order; two calls made while a check runs join it (one set of requests to the transport); the newest result is `status`; `statusUpdates()` emits the current status first and then each change once; a check after `setAddress` goes to the new address
- [ ] T022 [US1] Implement `OllamaService` (status and single-flight check only) and `ServerStatus` in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaService.swift`; log `check status=<status> ms=<n>` in category `ollama`; the tests pass
- [ ] T023 [US1] Wire the services in `App/AppEnvironment.swift`: create `OllamaSettings` over the existing `UserDefaultsSettingsStore`, and an `OllamaService` whose transport factory builds an `OllamaURLSessionTransport` for the current `LoopbackAddress`; expose both on the environment; at launch run one check and then `applyDefaultModelIfNeeded()` (implemented in T027), so the recommended model is chosen without opening Settings (FR-006), with a test in T026 that a fresh store with the model installed ends up with it chosen
- [ ] T024 [US1] Create `App/Windows/OllamaSettingsView.swift` with the Connection section from `contracts/ui-contract.md`: a scrolling view like `StorageSettingsView`, the `Server address` field with **Apply** (a rejected address shows `Memorri only talks to Ollama on this Mac. Use localhost, 127.0.0.1 or ::1.` and keeps the previous value), the status line with the exact texts, and **Check connection**; check when the section opens and after Apply, never on the main actor; replace the Ollama placeholder in `App/Windows/SettingsView.swift` (route `.ollama` to the new view and remove its `comingLater` text)
- [ ] T025 [US1] Run quickstart Scenario 1 on this Mac (real server, a closed port, the fake server in `slow` mode, the four non-local addresses, then `lsof` for connections), repeat the status check 10 times across the three situations (server running, stopped, chosen model missing) and record that each result is correct and appears within 5 s (SC-001) and fix any difference from `contracts/ui-contract.md`

**Checkpoint**: User Story 1 works on its own: the section shows a correct status within 5 s in every situation.

---

## Phase 4: User Story 2 - Choose the model that reads the screenshots (Priority: P1)

**Goal**: a picker of the vision-capable installed models, with the recommended one preselected and honest warnings.

- [ ] T026 [US2] Extend `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaServiceTests.swift` with failing tests: `modelList()` returns only the models with `readsImages` and `hiddenCount` for the others (this Mac's six models give two usable and four hidden); `applyDefaultModelIfNeeded()` chooses `qwen3.8:27b-mlx` when nothing is chosen and it is installed, chooses nothing when it is not, and never replaces an existing choice; a chosen model that disappears keeps its name and the status becomes `.modelMissing(name)`; models without a `capabilities` key are resolved through `/api/show`
- [ ] T027 [US2] Implement `modelList()`, `applyDefaultModelIfNeeded()`, `ModelList` and `client()` in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaService.swift`; the tests pass
- [ ] T028 [US2] Add the Model section to `App/Windows/OllamaSettingsView.swift`: the `Model` picker of the usable models, the refresh button, the note `<n> installed models are hidden because they cannot read images.` (omitted for 0), the recommended model chosen on first use, and the warning `The chosen model <name> is no longer installed.`; the list is loaded when the section opens and on refresh, off the main actor
- [ ] T029 [US2] Run quickstart Scenario 2 (the real server's six models with the time the list takes to appear, which must be within 3 s (SC-002), then the fake server with no vision model and with a dropped model) and fix any difference

**Checkpoint**: User Stories 1 and 2 work: the user connects and picks a usable model.

---

## Phase 5: User Story 4 - Analysis jobs run one at a time in the background, with retries (Priority: P2)

**Goal**: a durable, serial queue that runs test jobs through the model, retries, waits for the server and survives restarts. (User Story 3, the spike, is in Phase 1.)

- [ ] T030 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SamplePictureTests.swift`: `SamplePicture.make(longEdge:)` returns an image whose longer side equals the argument for 1024, 2048 and 4096, is not blank (its pixels have more than one colour), is identical in two calls (deterministic), and `SamplePicture.knownTexts` contains `Team sync` and `10:00`
- [ ] T031 [US4] Implement `SamplePicture` in `Packages/MemorriCore/Sources/MemorriCore/Inference/SamplePicture.swift` (Core Graphics and Core Text, no asset file, drawn like the spike picture); the tests pass
- [ ] T032 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ModelTestJobTests.swift` with `FakeOllamaTransport`, a fake picture provider added to `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift` and the real database: `ModelTestJob.schema` accepts a known-good answer and the prompt and schema versions are `test-v1`; `ModelTestJobRunner.run` returns `.success` and writes a `success` run with the model, think, `image_long_edge`, versions, duration, `request_json` containing `[picture` and no base64 text, and the raw answer; an invalid answer returns `.transient("invalid answer")` and writes a `failed` run with the raw answer; a timeout gives `.transient("timed out")`; HTTP 500 gives `.transient("server error 500")`; HTTP 400 gives `.permanent("request rejected")`; a refused connection gives `.serverUnavailable`; a missing picture gives `.permanent("picture no longer stored")` and writes no run; attempt 2 and 3 add the repair note naming the problem to the prompt when `spike-report.md` kept it, and leave the prompt unchanged when it recorded that the note does not help (write the test for the recorded branch); with the recorded decision `useNativeFormat` false the request has no `format` and the prompt carries the schema; a job with no `image_id` uses `SamplePicture`; a job whose capture is deleted between start and write fails with `picture no longer stored` instead of crashing
- [ ] T033 [US4] Implement `ModelTestJob`, `ModelTestJobRunner` and `JobOutcome` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ModelTestJob.swift` (reads the settings at the start of each attempt; builds the request with `useNativeFormat` and the repair note as recorded in `spike-report.md`; logs `request model=… think=… size=… attempt=… ms=… outcome=… reason=…` in category `ollama`); the tests pass
- [ ] T034 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisQueueTests.swift` with a fake runner, a fake clock, a fake `QueueSleeping` and a fake `ready` gate added to `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift`, and the real store: with 10 queued jobs the maximum number running at once is 1 and they run oldest first; a job with a future `not_before` is skipped until its time; a transient failure gives `not_before` of 10 s, then 60 s, and the job is `failed` with the reason at the third failure; a permanent failure fails at once with attempts unchanged; `.serverUnavailable` returns the job to `waiting` with attempts unchanged and fails nothing; a gate that is not `.reachable` holds the queue without using attempts, reports a `holdingReason` mapped from the server status (`notReachable` and `timedOut` give `Ollama not reachable`; `noVisionModel` and `modelMissing` give `model not installed`; `noModelChosen` gives `choose a model`), rechecks every 30 s and resumes by itself when the gate opens; `start()` recovers `running` jobs with attempts unchanged; `pause(true)` lets the running job finish and starts nothing new, and the flag is stored in `OllamaSettings` so a new queue starts paused; `pause(false)` and `nudge()` continue; `retryFailed` and `clearFinished` behave as in the data model; `progressUpdates()` emits the current progress first and each change once; `enqueueTest(imageID:)` creates a waiting job and wakes the loop
- [ ] T035 [US4] Implement `AnalysisQueue`, `RetryPolicy` (`standard`: 3 attempts, waits 10 s and 60 s), `QueueProgress`, `QueueSleeping` and the real sleeper in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisQueue.swift` (one long-lived loop, so one job at a time by construction; logs in category `analysis`: `job started id=… attempt=…`, `job finished id=…`, `job failed id=… reason=…`, `queue holding reason=…`, `queue resumed`, `recovered running=…`); the tests pass
- [ ] T036 [US4] Wire the queue in `App/AppEnvironment.swift`: create `AnalysisStore` and `StoredPictureProvider` from the storage context, the `ModelTestJobRunner`, the `AnalysisQueue` with the service's status as its gate, and start it at launch (after the storage is open and after the launch-time default model choice from T023); do nothing when the storage is unavailable; expose `enqueueTest()` that uses `CaptureStore.newestImageID()` or the built-in sample when there is none, and whether it used the newest capture
- [ ] T037 [US4] Add the Test and Queue sections to `App/Windows/OllamaSettingsView.swift` per `contracts/ui-contract.md`: **Test the model** with the note `Using the newest capture.` or `Using the built-in sample picture.` and the result line (`Answer valid in <s> s: "<first 60 characters>"` or `Failed: <reason>`), and the queue block with counts `Waiting · Running · Finished · Failed`, the last 5 failures, **Retry failed** and **Clear finished**
- [ ] T038 [US4] Run quickstart Scenario 3 on this Mac (real server and a stored capture; then the built-in sample; then delete captures and check that the runs are gone with them) and fix any difference
- [ ] T039 [US4] Run the queue part of quickstart Scenario 4 with `scripts/fake-ollama.py` (5 jobs in `slow` mode with the log order checked, quit and relaunch during a job, `invalid` mode to the third failed attempt and **Retry failed**, stop and start the fake server, **Clear finished**) and fix any difference (SC-005 to SC-008)

**Checkpoint**: User Stories 1, 2 and 4 work: test jobs run one at a time, retry, wait for the server and survive a quit.

---

## Phase 6: User Story 5 - See progress in the menu and control the queue (Priority: P2)

**Goal**: one analysis line in the menu, and Pause and Resume that survive a restart.

- [ ] T040 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/AnalysisLineTests.swift` for the exact texts: `Analysis: idle`; `Analysis: 3 waiting`; `Analysing 1 of 4…` (n is running plus waiting); `Analysis waiting: Ollama not reachable`, `Analysis waiting: model not installed`, `Analysis waiting: choose a model`; `Analysis paused`; failures appended as `, <k> failed` (`Analysis: 2 waiting, 1 failed`, `Analysis: idle, 1 failed`, `Analysis paused, 1 failed`); precedence paused, then holding, then running, then waiting, then idle
- [ ] T041 [US5] Implement `AnalysisLine` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/AnalysisLine.swift`; the tests pass
- [ ] T042 [US5] Show progress in the menu: add `analysisProgress` and `analysisLine` to `App/AppState.swift` (set from the queue's `progressUpdates()`), a disabled line under the last-capture line in `App/MenuContent.swift`, and the **Pause analysis** / **Resume analysis** item below the capture items (calls the queue's `pause`); repeat the pause toggle in the queue block of `App/Windows/OllamaSettingsView.swift`
- [ ] T043 [US5] Run the menu and pause part of quickstart Scenario 4 (read the menu line as jobs progress, pause during a job, relaunch while paused, resume within 5 s, menu and Settings responsive during a job) and fix any difference (SC-009, SC-011)

**Checkpoint**: User Stories 1, 2, 4 and 5 work: progress is visible and the user can pause.

---

## Phase 7: User Story 6 - Tune how the model is asked (Priority: P3)

**Goal**: think level and timeout are editable, validated and applied to the next job only.

- [ ] T044 [US6] Extend `Packages/MemorriCore/Tests/MemorriCoreTests/ModelTestJobTests.swift` with failing tests: the runner reads think level, timeout and model from `OllamaSettings` at the start of each attempt, so a change between two attempts applies to the second and a change during an attempt does not alter the running one; the request timeout equals `timeoutSeconds`; for a model without `thinking` the wire value is always `false` whatever the setting; `ThinkWireValue` follows the spike decision for models that accept levels and for those that accept only the boolean
- [ ] T045 [US6] Adjust `ModelTestJobRunner` and `ThinkWireValue` in `Packages/MemorriCore/Sources/MemorriCore/Analysis/ModelTestJob.swift` and `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaClient.swift` so the tests pass (settings read once per attempt, wire value from the spike)
- [ ] T046 [US6] Add the Thinking and Timeout sections to `App/Windows/OllamaSettingsView.swift`: the `Thinking` picker (Off, Low, Medium, High) disabled with `This model does not support thinking.` when the chosen model lacks it, the note `This model only supports thinking on or off; Low, Medium and High all mean on.` when the spike shows boolean only, the `Stop a request after (seconds)` field (10 to 1800, `Enter a value between 10 and 1800.` and the previous value kept), and the note `Applies to the next job.`
- [ ] T047 [US6] Run quickstart Scenario 5 (think level in the run record, disabled state for a model without thinking, timeout 5 rejected, timeout 10 against the fake server in `slow` mode with a 15 s answer, change during a running job) and fix any difference

**Checkpoint**: all six user stories work.

---

## Phase 8: Polish and cross-cutting concerns

- [ ] T048 [P] Update the design documents to match what was built: `specs/003-ollama-connector/contracts/core-interfaces.md` and `plan.md` (for example `StoredPictureProvider` in core instead of an app adapter, `CaptureStore.image(id:)` and `newestImageID()`, `ThinkWireValue`, `OllamaClientError`), `data-model.md` and `research.md` for any deviation, and set ADRs 0011, 0012 and 0013 in `docs/architecture/decisions/` from `Proposed` to `Accepted` (and ADR 0005 to `Superseded by 0013` only if the spike changed the decision)
- [ ] T049 [P] Update `DEVELOPER.md` (installing Ollama and the recommended model, the Ollama section of Settings, `scripts/fake-ollama.py` and its modes, the log categories `ollama` and `analysis`, that the network is allowed in exactly one file and why) and the status line in `README.md` (the app now connects to a local Ollama server and runs test jobs; it does not read screenshots yet)
- [ ] T050 Run `swift test --package-path Packages/MemorriCore` and a clean `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode clean build`; both must pass with no warnings from our code; run `lsof -i -a -p $(pgrep -x Memorri)` during a real test job and confirm connections only to localhost; confirm with `grep -rn URLSession App Packages/MemorriCore/Sources` that only `OllamaURLSessionTransport.swift` uses it
- [ ] T051 Validate a fresh clone: clone the repository into a temporary directory on this branch, follow only `DEVELOPER.md` to build and test, and confirm everything passes; commit `Package.resolved` if the build changes it; time it
- [ ] T052 Set the status of 003 to `Done` in `docs/roadmap.md`, fill the observed results (spike numbers and scenario outcomes, noting which success criteria were observed by hand) into `specs/003-ollama-connector/quickstart.md`, and prepare the pull request description with the Definition of done checklist from `DEVELOPER.md`

---
## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup and spikes)**: T001 then T002 then T003; T004 is independent. Start T002 in the background at once (it takes tens of minutes) and continue with Phase 2 while it runs. Only T009 needs the spike's default values, so finish T003 before T009.
- **Phase 2 (Foundational)**: after T001; blocks every user story. The test and implementation pairs proceed pair by pair. Tasks that edit `Fakes.swift` (T011, T032 and T034) are sequential.
- **US1 (Phase 3)**: after Foundational. MVP.
- **US2 (Phase 4)**: after US1 (same service and same view).
- **US4 (Phase 5)**: after Foundational and US2 (the runner needs a chosen model and the service); its tests can start after Foundational.
- **US5 (Phase 6)**: after US4 (needs the queue's progress).
- **US6 (Phase 7)**: after US4 (the runner and the view).
- **Polish (Phase 8)**: after all stories.

### Within Each User Story

- Tests first and failing, then the core type, then wiring, then the view, then the quickstart scenario.
- `OllamaSettingsView.swift` is edited by US1, US2, US4, US5 and US6, so those view tasks follow in order.

### Parallel Opportunities

- Foundational tests in distinct files that do not touch `Fakes.swift`: `LoopbackAddressTests`, `JSONValueTests` with `SchemaValidatorTests`, `OllamaSettingsTests`.
- `SamplePictureTests` and `AnalysisLineTests` while other stories are in progress.
- The two documentation tasks in Polish.

---

## Parallel Example: Foundational tests

```bash
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/LoopbackAddressTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/JSONValueTests.swift and SchemaValidatorTests.swift"
Task: "Write failing tests in Packages/MemorriCore/Tests/MemorriCoreTests/OllamaSettingsTests.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 (spike running in the background) and Phase 2 (foundation).
2. Phase 3: the Ollama section shows an accurate status.
3. **Stop and validate** with quickstart Scenario 1.

### Incremental Delivery

1. The spike answers the model questions first (structured output with pictures, cost per size, accepted think values).
2. US1 and US2 give a working, safe connection and a model choice.
3. US4 adds the durable serial queue and the test job; US5 makes it visible and pausable; US6 adds tuning.
4. Polish closes the docs, the no-network and fresh-clone checks.

---

## Notes

- Commit after each task or small group, on branch `003-ollama-connector`, with English Conventional Commit messages (`feat(003): …`, `test(003): …`, `docs(003): …`). Do not push or open a PR until asked.
- The spike uses only the synthetic picture; never send or commit a real screenshot or model output from real sessions.
- Running the real model loads about 18 GB into memory; tell the user before starting the long spike run.
- Changes to the UI can be driven from the terminal with the automation available on this Mac, as in specs 001 and 002. Check which application is frontmost before sending any keystroke, and set field values through accessibility (Memorri is an accessory app and does not come to the front on its own).
