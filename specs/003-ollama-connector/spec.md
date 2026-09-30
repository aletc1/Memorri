# Feature Specification: Connect to the local model and run analysis jobs in the background

**Feature Branch**: `003-ollama-connector`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "Settings for Ollama URL, vision model picker (from /api/tags with a capability check), think level, timeout and a health check. Include a spike proving qwen3.8:27b-mlx honours a JSON-schema format with images attached, and measure latency at several image sizes. Add a serial background queue with retries and progress shown in the menu (ADR 0005)."

## Clarifications

### Session 2026-09-30

- Q: When cleanup removes a capture, should the model's raw answers for its pictures be removed too, or kept on their own? → A: Removed together with the capture, in every kind of cleanup (age-based, automatic retention and "delete all captures"). Run records from "Test the model" that have no capture are removed by **Clear finished**.
- Q: After the queue finishes, should Memorri ask Ollama to free the model's memory or leave it loaded? → A: Leave it to Ollama's own default; Memorri sends no unload request and has no setting for it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect to the local model server and see that it works (Priority: P1)

In Settings the user finds an Ollama section. It shows the server address (already set to the standard address on this Mac), a **Check connection** button and the result: the server is reachable and its version, or exactly why it is not (nothing is listening, it took too long, the chosen model is not installed, no installed model can read images). The check also runs when the section opens and when the address changes.

**Why this priority**: Every later step sends screenshots to this server. If the user cannot tell whether it is running and usable, nothing else can be trusted or debugged.

**Independent Test**: With the server running, open the section and see "reachable" with its version. Stop the server, click **Check connection**, and see a clear "not reachable" message within 5 seconds. Start it again and see "reachable" again.

**Acceptance Scenarios**:

1. **Given** the server is running on this Mac, **When** the user opens the Ollama section, **Then** the status shows reachable with the server version within 5 seconds.
2. **Given** the server is not running, **When** the user clicks **Check connection**, **Then** the status says it cannot be reached and suggests starting it, within 5 seconds.
3. **Given** the user enters an address that is not on this Mac (for example another computer's name or address), **When** they confirm, **Then** the address is rejected with an explanation that Memorri only talks to a server on this Mac, and the previous address is kept.
4. **Given** the user changes the address to another port on this Mac, **When** they confirm, **Then** the section checks the new address and shows its status.
5. **Given** the server answers but no installed model can read images, **When** the check finishes, **Then** the status says so and tells the user to install a vision model.

---

### User Story 2 - Choose the model that reads the screenshots (Priority: P1)

The user picks the model from a list of the models installed on the server. Only models that can read images are offered. When the recommended model is installed and nothing has been chosen yet, it is chosen for the user. If the chosen model is later removed from the server, the section says so.

**Why this priority**: The model is the heart of the product, and picking a model that cannot read images would fail silently later. The list must come from what is really installed.

**Independent Test**: With several models installed, open the picker and confirm that only vision-capable ones appear, that the recommended one is preselected on first use, and that a hint says how many installed models are hidden because they cannot read images.

**Acceptance Scenarios**:

1. **Given** the server has both vision and non-vision models, **When** the user opens the picker, **Then** only vision-capable models are listed, and a note gives the number of hidden ones.
2. **Given** the recommended model (`qwen3.8:27b-mlx`) is installed and no choice was made, **When** the section opens the first time, **Then** it is selected.
3. **Given** the recommended model is not installed, **When** the section opens the first time, **Then** nothing is selected, and the section says a model must be chosen before analysis can run.
4. **Given** the chosen model is removed from the server, **When** the section is next checked, **Then** a warning names the model and says it is no longer installed; the choice is not silently replaced.
5. **Given** a new model is installed while Settings is open, **When** the user presses the refresh button, **Then** it appears in the list.

---

### User Story 3 - Prove that the model returns structured answers from pictures, and know what it costs (Priority: P1)

Before building extraction on top of it, the team proves, with a spike on the real model, that the model returns answers that follow a required JSON schema when pictures are attached, and measures how long it takes at several picture sizes. The result is a written report that settles which way the app asks for structured answers and what the default picture size and timeout should be.

**Why this priority**: The whole extraction design (ADR 0005) assumes the model obeys the required schema with pictures attached. If it does not, the plan changes (ask in the prompt, then validate and repair). This must be known before specs 004 and later.

**Independent Test**: Read the report: it states, for at least four picture sizes spanning the analysis copy range, how many of the runs returned valid answers and how long they took, and it records the decision.

**Acceptance Scenarios**:

1. **Given** the recommended model and a test picture with known content, **When** the spike asks for an answer in a required JSON schema with the picture attached, **Then** the report shows what share of runs produced an answer that matches the schema exactly.
2. **Given** the same test, **When** the spike repeats it at four or more picture sizes (at least 1024, 2048 and 3072 pixels on the longer side, and one more), **Then** the report lists time to a full answer for each size, and how it varies between runs.
3. **Given** the thinking option is off and on, **When** the spike compares them, **Then** the report states the effect on answer validity and time.
4. **Given** the results, **When** the report is finished, **Then** it records one decision (use the model's native structured output, or fall back to asking in the prompt and then checking and repairing), a recommended default timeout, and a recommended default picture size, and ADR 0005 is updated or superseded accordingly.
5. **Given** only synthetic or non-sensitive test pictures are used, **When** the report is committed, **Then** it contains no screenshot of the user's real sessions.

---

### User Story 4 - Analysis jobs run one at a time in the background, with retries (Priority: P2)

Work for the model is put in a queue. One job runs at a time, oldest first. A job that fails for a temporary reason (the server is busy or slow, the connection drops, the answer is malformed) is tried again a limited number of times with growing waits. The queue survives quitting and relaunching the app. Progress shows in the menu.

In this spec jobs come only from a **Test the model** button in Settings: it sends a small fixed request with the newest stored analysis copy (or a built-in sample when there is none) and shows whether a valid structured answer came back and how long it took. Screenshots are not queued automatically yet; that is added with extraction (spec 004).

**Why this priority**: A 27-billion-parameter model takes seconds to minutes per picture and must not be run in parallel on a normal Mac. The queue is the backbone for every later analysis step, and it has to be reliable before real work depends on it.

**Independent Test**: Start several test jobs, watch the menu count down while only one runs at a time, quit during a job, relaunch, and see the job run again; stop the server mid-way and see the queue wait and resume.

**Acceptance Scenarios**:

1. **Given** five jobs are queued, **When** they run, **Then** never more than one runs at any moment and they run oldest first.
2. **Given** a job is running, **When** the user quits and relaunches the app, **Then** the job is back in the queue without having used up an attempt, and runs again.
3. **Given** the server stops while jobs are waiting, **When** the next job is due, **Then** the queue waits, the menu says it is waiting for Ollama, and no job is marked failed.
4. **Given** the server is started again, **When** it is reachable, **Then** the queue resumes by itself within 35 seconds.
5. **Given** a job fails for a temporary reason, **When** attempts remain, **Then** it is tried again after a wait that grows, up to 3 attempts in total.
6. **Given** a job has used all its attempts, **When** the last one fails, **Then** it is marked failed with a short reason and stays listed until the user retries or clears it.
7. **Given** a job fails for a permanent reason (for example the picture it needs is no longer stored), **When** it fails, **Then** it is marked failed at once without further attempts.
8. **Given** the queue is busy, **When** the user opens the menu or Settings, **Then** both respond at once.

---

### User Story 5 - See progress in the menu and control the queue (Priority: P2)

The menu shows one line for analysis under the last capture line: idle, how many are waiting, the job being worked on, waiting for the server, or how many failed. The user can pause and resume analysis from the menu. The Ollama section in Settings shows the counts and the recent failures with their reasons, and offers **Retry failed** and **Clear finished**.

**Why this priority**: Without visible progress, a slow background job looks like a hang. Pause lets the user free the Mac's graphics and memory on demand.

**Independent Test**: Queue jobs, read the menu line as they progress, pause, confirm nothing new starts, resume, and confirm the queue continues.

**Acceptance Scenarios**:

1. **Given** nothing is queued, **When** the user opens the menu, **Then** the analysis line says `Analysis: idle`.
2. **Given** three jobs are queued and one is running, **When** the user opens the menu, **Then** the line shows the running job and how many are waiting, and updates about every 5 seconds while the menu is open.
3. **Given** the user chooses **Pause analysis**, **When** a job is running, **Then** the running job finishes, nothing new starts, and the menu line says analysis is paused and offers **Resume analysis**.
4. **Given** the app is quit while paused, **When** it is relaunched, **Then** analysis is still paused.
5. **Given** jobs have failed, **When** the user clicks **Retry failed**, **Then** they return to the queue with fresh attempts.
6. **Given** finished jobs are listed, **When** the user clicks **Clear finished**, **Then** completed and failed entries are removed from the list, and waiting and running jobs are not.

---

### User Story 6 - Tune how the model is asked (Priority: P3)

The user can set how much the model thinks (off, low, medium or high) and how long a single request may take before it counts as timed out. The thinking control is only available when the chosen model says it supports thinking. Changes apply to the next job; a job already running is not disturbed.

**Why this priority**: Useful for trading accuracy against speed, but sensible defaults (set from the spike) make the feature work without it.

**Independent Test**: Choose a model that supports thinking, set the level and timeout, run a test job, and confirm the run record shows the values used.

**Acceptance Scenarios**:

1. **Given** the chosen model supports thinking, **When** the user opens the section, **Then** the think level control is enabled with the default from the spike report.
2. **Given** the chosen model does not support thinking, **When** the user opens the section, **Then** the think level control is disabled and says why.
3. **Given** the user enters a timeout outside the allowed range, **When** they confirm, **Then** the app explains the range and keeps the previous value.
4. **Given** a job is running, **When** the user changes the think level or timeout, **Then** the running job keeps its values and the next job uses the new ones.
5. **Given** a request takes longer than the timeout, **When** the time is up, **Then** the request is abandoned and counts as a temporary failure.

---

### Edge Cases

- The app starts while the server is not running: nothing fails; the queue waits and the menu says so.
- The first request after the server (or its default idle period) has unloaded the model is very slow because the model must be loaded into memory again: the timeout default is chosen from the spike so this does not count as a failure, and the menu keeps saying it is working.
- The server answers with text that is not valid JSON, or valid JSON that does not match the required schema: the attempt counts as a temporary failure and the raw answer is kept.
- The model takes the whole timeout and produces nothing: the request is abandoned and retried within the attempt limit.
- The user changes the server address or model while jobs are queued: waiting jobs use the new values when they run; the running job is not interrupted.
- The chosen model is removed from the server while jobs are queued: the queue waits (no attempts used), the menu says the model is not installed, and it resumes when the model is available again or another is chosen.
- A queued job refers to a picture that retention has already deleted: the job fails at once with "picture no longer stored"; the run records of that capture were deleted with it.
- The Mac sleeps during a job: the request may time out; the job is retried normally after wake.
- Very many jobs are queued: the menu shows counts, not a list; the queue stays ordered and persistent.
- The app crashes during a job: same as quitting; the job returns to the queue without using an attempt.
- The server address uses a name that resolves to another machine: only addresses that mean this Mac are accepted; names other than `localhost` are rejected.
- Two Settings windows or rapid clicks on **Check connection**: only one check runs at a time, and the latest result is shown.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings MUST have an Ollama section (replacing the placeholder from spec 001) with: server address, model picker, think level, timeout, a **Check connection** action with its result, **Test the model**, and the queue status described in FR-016.
- **FR-002**: The server address MUST default to the standard local address (`http://localhost:11434`). Only addresses that mean this Mac (`localhost`, `127.0.0.1`, `::1`, with any port) MUST be accepted. Anything else MUST be rejected with an explanation and the previous value kept (Constitution principle I).
- **FR-003**: A connection check MUST report exactly one of: reachable with the server version; not reachable (nothing listening); timed out; reachable but no installed model can read images; reachable but the chosen model is not installed. It MUST finish or time out within 5 seconds and MUST NOT freeze the interface.
- **FR-004**: The check MUST run when the Ollama section opens, when the address changes and when the user asks. Only one check runs at a time.
- **FR-005**: The model picker MUST list the models installed on the server that can read images, taken from the server's own list and capability information. It MUST say how many installed models are hidden because they cannot read images. It MUST be refreshable.
- **FR-006**: When no model has been chosen and `qwen3.8:27b-mlx` is installed, it MUST be chosen, at launch as well as when the section opens, so analysis never waits for a choice the app could have made. Otherwise nothing is chosen and analysis waits with the message "Choose a model".
- **FR-007**: If the chosen model is not installed, the section MUST warn and keep the choice. It MUST NOT replace the choice on its own.
- **FR-008**: The think level MUST be one of off, low, medium, high, with the default set from the spike report, and MUST be available only when the chosen model reports thinking support.
- **FR-009**: The timeout for one request MUST be settable from 10 to 1800 seconds, with the default set from the spike report. An out-of-range value MUST be rejected with the range shown and the previous value kept.
- **FR-010**: Analysis requests MUST attach the stored analysis copy, ask for an answer that matches a required JSON schema, and use a temperature near zero. The answer MUST be checked against the schema; a mismatch is a failed attempt. The spike (FR-018) decides whether the server's own structured-output feature is used or the schema is given in the prompt and the answer is then checked and repaired (ADR 0005).
- **FR-011**: Every model run MUST be recorded with: the job, a reference to the picture (not an embedded copy), the model, the think level, the size of the picture sent, a prompt version, a schema version, the time it started, how long it took, the attempt number, the outcome with a short reason, and the raw answer. A run record that belongs to a capture's picture MUST be deleted together with that capture in every kind of cleanup (age-based, automatic retention and delete all), because the raw answer can contain text read from the screen. Anything derived later from the answers, such as items and their evidence crops, is not affected (spec 002, FR-023, ADR 0010). Run records with no capture (from the built-in sample) are removed by **Clear finished**.
- **FR-012**: The queue MUST run one job at a time, oldest first, and MUST be kept on disk so no job is lost when the app quits, crashes or restarts. A job running at that moment MUST return to the queue without using an attempt.
- **FR-013**: A job that fails for a temporary reason (timeout, lost connection, server error, invalid or non-matching answer) MUST be retried with growing waits, at most 3 attempts in total. A job that fails for a permanent reason (its picture is no longer stored, the request is rejected as invalid) MUST fail at once. A job out of attempts MUST be marked failed with a short reason.
- **FR-014**: When the server is not reachable, or the chosen model is missing or unset, the queue MUST wait without using attempts or failing jobs, say why in the menu, and resume by itself within 35 seconds of the condition clearing.
- **FR-015**: Jobs in this spec MUST be created only by **Test the model**, which sends a small fixed request with the newest stored analysis copy, or a built-in sample when no capture exists, and reports whether a valid structured answer came back and how long it took. Captures MUST NOT be queued automatically until extraction exists (spec 004).
- **FR-016**: The menu MUST show one analysis line under the last capture line with these texts: `Analysis: idle`, `Analysis: <n> waiting`, `Analysing 1 of <n>…`, `Analysis waiting: <reason>`, and `Analysis paused`, with `, <k> failed` added to whichever applies when jobs have failed (for example `Analysis: idle, 1 failed`). It MUST offer **Pause analysis** and **Resume analysis**, and the paused state MUST persist across restarts. The Ollama section MUST show counts of waiting, running, finished and failed jobs, the recent failures with reasons, **Retry failed** and **Clear finished**. No macOS notifications or alert windows are used.
- **FR-017**: Changes to the address, model, think level or timeout MUST apply to jobs that start after the change and MUST NOT interrupt the job running.
- **FR-018**: A spike on the real recommended model, with pictures attached, MUST be carried out and written up: the share of runs that return an answer matching the required schema, and the time to a complete answer, at four or more picture sizes (at least 1024, 2048 and 3072 pixels on the longer side), with thinking off and on, repeated at least 5 times per combination. The report MUST record the decision on how structured answers are requested, a default timeout, a default think level and a default picture size, and ADR 0005 MUST be updated or superseded to match. Test pictures MUST NOT come from the user's real sessions.
- **FR-019**: Requests MUST go only to the accepted local address. The app MUST NOT send captured content anywhere else, and the source scan test from spec 001 MUST be updated so that network use is allowed only in the one component that talks to the local server, which itself enforces FR-002.
- **FR-020**: The interface MUST stay responsive (menu and Settings respond within 1 second) while a job is running or a check is in progress.

### Key Entities

- **Connection settings**: the server address, the chosen model, the think level and the timeout.
- **Server status**: the result of the last check (reachable with version, not reachable, timed out, no vision model, chosen model missing) and when it was taken.
- **Model choice**: the model name and what it can do (reads images, supports thinking).
- **Analysis job**: one unit of work for the model, created with a kind (in this spec, the test), the picture it needs, a state (waiting, running, finished, failed, paused with the queue), an attempt count and a short reason when failed.
- **Model run record**: one attempt of a job, with the model, settings used, prompt and schema versions, timing, outcome and the raw answer. It lives and is deleted with the capture it came from.
- **Queue progress**: what the menu line shows, derived from the counts of jobs and the server status.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 10 trials across three situations (server running, server stopped, chosen model missing), the status shown is the correct one and appears within 5 seconds every time.
- **SC-002**: The model list appears within 3 seconds with the models installed on the developer Mac, and no model that cannot read images is ever offered.
- **SC-003**: Addresses that do not mean this Mac are rejected in 100% of at least 6 tested examples (other hostnames, private network addresses, public addresses), and the standard local address and other local ports are accepted.
- **SC-004**: The spike report covers at least four picture sizes, with at least 5 runs per size and per thinking setting, states the valid-answer rate and the time to a complete answer for each, and records the decision and the default values; ADR 0005 reflects it.
- **SC-005**: With 10 queued jobs, at no moment do two run at once (checked in the log), and they run oldest first.
- **SC-006**: After quitting during a job and relaunching, 0 jobs are lost, the running one is queued again, and 0 attempts were used by the quit.
- **SC-007**: After the server is stopped with jobs queued, the menu names the reason within 35 seconds and no job is marked failed; after it is started again, the queue resumes within 35 seconds without any action.
- **SC-008**: In 5 forced cases of an invalid answer, each job is tried exactly 3 times, then shown as failed with a reason.
- **SC-009**: While a job is running, the menu and Settings respond within 1 second.
- **SC-010**: 100% of model runs have a complete run record, including runs that failed, and no record contains an embedded picture.
- **SC-011**: After **Pause analysis**, no new job starts while paused and the paused state survives a relaunch; after **Resume analysis**, the queue continues within 5 seconds.

## Assumptions

- Builds on spec 002: the stored analysis copies and the database exist. Extraction (reading text, finding appointments) is out of scope and arrives in specs 004 and later; this spec delivers the connection, the settings, the spike and the queue.
- Memory use of the model is left to Ollama: Memorri does not ask it to unload the model and offers no setting for it. The user can still unload it with Ollama's own tools.
- The server is Ollama on the same Mac, which is already installed here (version 0.34.4) with `qwen3.8:27b-mlx`, a model that reports vision, tools and thinking support. Remote servers are not supported, because captured content must never leave this Mac (Constitution principle I).
- Captures are not queued automatically in this spec. Running the 27-billion-parameter model on every capture before extraction exists would use time and memory for results nobody reads. The queue is exercised by the **Test the model** action, and spec 004 adds real jobs to the same queue.
- Default values for the think level, the timeout and the picture size come from the spike report (ADR 0013): thinking off, timeout 300 seconds, picture size 2048 (the existing default). The spike also decided that the server's own structured-output feature is used (the prompt-only fallback was not reliable) and that stored pictures are converted to JPEG before they are sent, because the server does not accept HEIC.
- The retry policy is 3 attempts in total with waits of about 10 seconds and then 60 seconds. The precise waits can be tuned after the spike without changing the requirements.
- The queue is kept in the same local database as the captures and is migrated by the same mechanism (spec 002, ADR 0003).
- The pictures sent to the model are the analysis copies stored by spec 002; the full-resolution pictures are kept for evidence and text recognition.
- Raw answers from the model are part of the raw ingestion: they live and expire with the capture they came from (retention default 7 days), so no screen text outlives its capture. Items found later keep their own evidence (ADR 0010).
- Settings values are stored in the same preferences as earlier specs. The Ollama section replaces the placeholder shown since spec 001.
- Testing with the real server and model is done on the developer Mac using the terminal-driven automation available there; unit tests use a fake server.
