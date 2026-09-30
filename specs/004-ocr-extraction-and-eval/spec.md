# Feature Specification: Read captures and find appointments and tasks, measured against a golden set

**Feature Branch**: `004-ocr-extraction-and-eval`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "Run Apple Vision OCR per capture and store lines with boxes. Classify screen type (calendar month/week/day, email, chat, document). Use per-type prompts and a JSON schema; the model cites OCR line IDs. Extract appointments, tasks ("X needs Y") and deadlines with reminders. Resolve relative dates using capture time, context timezone and calendar date headers. Guess missing durations from block height, else 1h, flagged as inferred. Detect the source context (which app, workspace or session a capture came from) automatically with manual override. Deliver the memorri-eval CLI and a golden set with precision, recall and field accuracy, and use it to set the downscale default (ADR 0004)."

## Clarifications

### Session 2026-09-30

- Q: Should Memorri record the titles of the windows visible on each display when it captures, so contexts can be matched on them? → A: Yes. The titles of windows visible on each display are stored with its picture and deleted with it, in every kind of cleanup.
- Q: What should `memorri-eval` do if the app's analysis queue has a job running? → A: Refuse to start and say to pause analysis first; an explicit option overrides the refusal.
- Q: Should analysis of new captures be on by default? → A: Yes. Every stored capture is queued; a Settings switch and the Pause control turn it off.
- Q: How strict should matching a found item to an expected one be on the title? → A: Same kind, titles at least 80% similar after ignoring case, spaces and punctuation (or one contains the other), and start or due date within 5 minutes; both thresholds are printed in the report.
- Q: When a capture is reanalysed, what happens to the earlier run's findings? → A: The new run's findings replace them; the earlier run's record and raw answer stay until the capture is deleted.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Measure extraction quality before trusting it (Priority: P1)

A developer runs one command, `memorri-eval`, over a folder of golden cases (a picture, the capture time and time zone, and the items a person would expect to find). The command runs the same reading and extraction steps the app uses and prints precision, recall and field accuracy, per case and overall, plus which expected items were missed and which found items were not expected. The run can be repeated with another picture size, model or prompt version, and the results compared with an earlier run.

**Why this priority**: The constitution makes prompt and model changes subject to measurement, and every other story in this spec is tuned with this tool. Without it, quality is a feeling.

**Independent Test**: Run the command on the tracked synthetic cases and get a report with the three measures; change one expected item in a case and see the score fall in the way predicted.

**Acceptance Scenarios**:

1. **Given** a folder of golden cases, **When** the developer runs the command, **Then** it prints precision, recall and field accuracy overall and per case, and lists each missed and each unexpected item.
2. **Given** a case where the extraction matches the expectation exactly, **When** it is scored, **Then** that case shows precision 1, recall 1 and field accuracy 1.
3. **Given** a case with one expected item missing from the result, **When** it is scored, **Then** recall falls and the missed item is named.
4. **Given** two runs with different settings (for example picture size), **When** the developer asks for a comparison, **Then** the report shows the difference in each measure.
5. **Given** a golden case that contains real captured data, **When** the repository is checked, **Then** only synthetic cases are tracked; real ones stay on the developer's Mac.
6. **Given** the server or model is unavailable, **When** the command runs, **Then** it stops with a clear message and scores nothing.

---

### User Story 2 - Read the text on every capture and keep it with its position (Priority: P1)

After a capture is stored, Memorri reads the text on each display's full-resolution picture and stores every line with its exact box, its confidence and a stable number within that picture. Nothing about the model is needed for this step, and it runs in the background.

**Why this priority**: The model cites these lines, and later specs crop evidence from their boxes (ADR 0004). Text with positions is the foundation of everything after it.

**Independent Test**: Capture a screen with known text, wait, and see stored lines whose text matches and whose boxes sit on the text in the picture.

**Acceptance Scenarios**:

1. **Given** a stored capture, **When** the reading step has run, **Then** each picture has its lines stored with text, box, confidence and number.
2. **Given** a picture with no readable text, **When** it is read, **Then** it is recorded as read with zero lines, not as failed.
3. **Given** a picture was already read, **When** the step is asked again, **Then** no duplicate lines are created.
4. **Given** a capture is deleted by any kind of cleanup, **When** it goes, **Then** its lines go with it.
5. **Given** the app is quit while reading, **When** it is relaunched, **Then** reading continues and loses nothing.

---

### User Story 3 - Find appointments, tasks and deadlines in a capture (Priority: P1)

For each read picture, Memorri asks the model to list the appointments, tasks and deadlines it shows, in a fixed structure, and to cite the numbers of the text lines each finding comes from. A finding has a kind (appointment, task, reminder or deadline), a title, and whichever of start, end, due date, people and place are visible. A task phrased as "X needs Y" is found as a task for X. Findings that do not cite existing lines are rejected, and answers that do not match the structure count as failed attempts and are retried by the queue. Results are kept per capture; merging the same item seen in several captures is a later spec.

**Why this priority**: This is the product's point: turning what was on screen into items. It builds on the queue from spec 003.

**Independent Test**: Capture or feed a synthetic calendar week with three meetings, an email saying "Anna needs the report by Friday", and see the four findings with correct titles, times and cited lines.

**Acceptance Scenarios**:

1. **Given** a read calendar picture with three meetings, **When** extraction runs, **Then** three appointments are stored, each with title, start and the cited line numbers.
2. **Given** an email whose text says that Anna needs a report by Friday, **When** extraction runs, **Then** a task for Anna with a due date of that Friday is stored.
3. **Given** a finding cites a line number that does not exist in the picture, **When** the answer is checked, **Then** that finding is discarded and the discard is recorded.
4. **Given** a picture with no appointments or tasks, **When** extraction runs, **Then** the result is an empty list and the capture is marked analysed.
5. **Given** the model's answer does not match the required structure, **When** it is checked, **Then** the attempt counts as failed and the queue retries it as in spec 003.
6. **Given** every finding, **When** it is stored, **Then** it keeps its cited lines, the model, prompt version, structure version and picture size used.

---

### User Story 4 - Use the right questions for each kind of screen (Priority: P1)

Before extracting, Memorri decides what kind of screen a picture shows: calendar month, calendar week, calendar day, email, chat, document, or other. The kind chooses the instructions and structure used for extraction (a week view needs day columns and time blocks; an email needs sender and date; a chat needs message times). A picture that cannot be classified is treated as other and gets general instructions.

**Why this priority**: One generic prompt cannot read a calendar grid and a chat equally well; classification is how each gets the context it needs.

**Independent Test**: Run the golden set and see a classification accuracy figure; every case has its kind in the report.

**Acceptance Scenarios**:

1. **Given** pictures of each supported kind, **When** classified, **Then** the kind is stored with the capture's picture and shown in the eval report.
2. **Given** a picture the classifier is unsure about, **When** classified, **Then** it is stored as other and general instructions are used.
3. **Given** a classified kind, **When** extraction runs, **Then** the instructions and structure versions used for that kind are recorded.
4. **Given** the golden set, **When** eval runs, **Then** classification accuracy is reported alongside the other measures.

---

### User Story 5 - Get real dates and times, not "tomorrow" (Priority: P2)

Findings with relative dates ("tomorrow", "by end of week", "next Monday", "in 2 days") and partial dates (a weekday only, a time only) are turned into full dates and times. The reference is the capture time, the time zone of the context the picture came from, and any date headers visible in the view (for example "Wednesday 14 October" at the top of a column). A weekday column in a calendar week gets the date from its header. Anything that cannot be resolved is stored as it was written and flagged unresolved, never guessed silently.

**Why this priority**: An item on the wrong day is worse than no item. Customer calendars in remote sessions show their own local time, so the reference cannot be the Mac's zone alone.

**Independent Test**: Golden cases with relative and header-based dates, at different capture times and zones, produce the expected dates.

**Acceptance Scenarios**:

1. **Given** an email captured on a Tuesday saying "tomorrow at 10", **When** resolved, **Then** the start is Wednesday at 10:00 in the context's time zone.
2. **Given** a week view with column headers, **When** a meeting sits in the Thursday column, **Then** its date is the date in that header.
3. **Given** "by end of week", **When** resolved, **Then** the due date is the last working day of that week, and the rule used is recorded.
4. **Given** a date that cannot be resolved (no header, no reference), **When** stored, **Then** it is kept as written and flagged unresolved.
5. **Given** the same text captured in a context whose time zone differs from the Mac's, **When** resolved, **Then** the result is expressed in the context's zone.
6. **Given** a capture taken just after midnight in the context's zone, **When** "today" is resolved, **Then** it uses the context's date, not the Mac's.

---

### User Story 6 - Fill in missing end times sensibly and say so (Priority: P2)

An appointment with a start but no visible end gets a duration: from the height of its block in a calendar view when that is visible, otherwise one hour. Any value that was guessed rather than read is flagged inferred, with the reason (block height or default), so later steps and the user can tell read values from guessed ones.

**Why this priority**: Calendars need an end time, but inventing it without saying so would break the "every field carries its source" principle.

**Independent Test**: A week-view case with a block spanning 90 minutes and a text-only meeting with no end produce a 90-minute and a 60-minute appointment, both flagged inferred with different reasons.

**Acceptance Scenarios**:

1. **Given** a week view where a block's height covers 90 minutes on the hour scale, **When** extracted, **Then** the end is 90 minutes after the start, flagged inferred by block height.
2. **Given** an appointment with an explicit end, **When** extracted, **Then** the end is used and not flagged.
3. **Given** an appointment with neither an end nor a visible block, **When** extracted, **Then** the duration is one hour, flagged inferred by default.
4. **Given** a block that would end after midnight or overlap the next day's header, **When** extracted, **Then** the end is cut at a sensible limit and flagged inferred.

---

### User Story 7 - Know which customer or session a capture came from (Priority: P2)

Memorri keeps a list of contexts (for example a customer's remote desktop or a workspace), each with a name, a time zone and hints such as window titles, domain names or keywords. For every capture it picks the best-matching context automatically from what is visible and what the window titles say, and shows which one it chose and why. The user can correct the choice for a capture, and the correction sticks: reanalysing does not undo it. A capture that matches nothing is marked unassigned and uses the Mac's time zone.

**Why this priority**: The time zone, and later the de-duplication and colour of items, depend on the context. It also decides which calendar an item belongs to when sync arrives.

**Independent Test**: Define two contexts with different hints and zones, capture or feed pictures for each, see each assigned correctly, override one, and see the override survive reanalysis.

**Acceptance Scenarios**:

1. **Given** a context whose hints appear in a capture, **When** the capture is analysed, **Then** that context is assigned, with the matched hints recorded.
2. **Given** hints from two contexts match, **When** analysed, **Then** the stronger match wins and the runner-up is recorded.
3. **Given** nothing matches, **When** analysed, **Then** the capture is unassigned and the Mac's time zone is used.
4. **Given** the user changes a capture's context, **When** the capture is analysed again, **Then** the user's choice is kept.
5. **Given** the user adds or edits a context in Settings, **When** they save, **Then** new analyses use it; existing captures keep their assignment until reanalysed.
6. **Given** a context is deleted, **When** captures referred to it, **Then** they become unassigned without losing their findings.

---

### User Story 8 - Tag each capture with what its environment looks like (Priority: P2)

For every picture Memorri also records a few facts about the environment it shows, as tags: the application (for example Outlook, Apple Mail, Teams, Slack, a web mail page), the operating system look (Windows, macOS, Linux), whether it is a remote or virtual desktop session and which client (for example Citrix, Remote Desktop, VMware, a browser-based session), the interface language, the date format and clock style (12 or 24 hour), light or dark theme, account or mailbox names and domains visible on screen, the calendar or folder name, time zone labels shown in the view, and the display's size and scale. Each tag has a value, a confidence and where it came from (a cited text line, a window title, or the look of the picture). Findings keep a copy of their picture's tags, so a later step can ask "did these two findings come from the same kind of place?".

**Why this priority**: The same meeting can appear in several captures, and two similar-looking items can be different. Knowing that one came from Outlook on a Windows remote desktop with 24-hour time, and the other from Apple Mail on the Mac, gives spec 005 cheap, reliable evidence for deciding "same" or "different", and improves context detection (story 7) and date reading (a 12-hour clock changes how "10:00" is read). Tags are hints, never proof: differing tags alone never mean different items.

**Independent Test**: Golden cases drawn as an Outlook week view on Windows with a remote desktop frame, an Apple Mail window on macOS, and a dark-theme chat each get the expected tags, and the eval report shows tag accuracy per tag.

**Acceptance Scenarios**:

1. **Given** a picture of a calendar in a known application, **When** it is analysed, **Then** an application tag with that name is stored with its confidence and source.
2. **Given** a picture shown inside a remote or virtual desktop window, **When** it is analysed, **Then** a remote-session tag names the client when it can be told, or says "remote, client unknown".
3. **Given** a 24-hour clock in a view, **When** analysed, **Then** the clock tag says 24-hour, and times are read accordingly (story 5).
4. **Given** an account name, email domain or mailbox name is visible, **When** analysed, **Then** it is stored as a tag with its source line, and used as a context hint (story 7).
5. **Given** a tag cannot be told, **When** analysed, **Then** it is absent or marked unknown, never guessed at high confidence.
6. **Given** a finding is stored, **When** it is read back, **Then** it carries its picture's tags as they were at that run.
7. **Given** a picture is reanalysed, **When** the new run ends, **Then** its tags are replaced by the new run's, and a tag the user set by hand (context choice) is kept.
8. **Given** golden cases with expected tags, **When** eval runs, **Then** it reports accuracy per tag and lists wrong and missing tags.

---

### User Story 9 - Choose the picture size from evidence (Priority: P3)

Using the golden set, the developer compares picture sizes (the longer side of the copy sent to the model) and records the best trade-off between accuracy and time. The default analysis size is changed if the evidence says so, and the decision is written down.

**Why this priority**: The size is a guess from spec 002 and 003; it should be replaced by a measured choice, but the app works with the current default meanwhile.

**Independent Test**: A written report lists measures and time for at least three sizes, states the chosen default, and the setting shows it.

**Acceptance Scenarios**:

1. **Given** the golden set, **When** eval is run at three or more sizes, **Then** the report shows precision, recall, field accuracy and time per size.
2. **Given** the results, **When** the report is finished, **Then** it states the default size and why, and the decision is recorded (an ADR update or a new one).
3. **Given** the chosen default differs from the current one, **When** the change ships, **Then** the storage setting shows the new default and existing choices by the user are kept.

---

### Edge Cases

- A display shows a full-screen video or an empty desktop: reading finds little or no text; extraction returns an empty list; nothing fails.
- A capture has several displays: each picture is read and extracted on its own; findings carry their display (ADR 0004).
- Text is very small or compressed (remote sessions): lines have low confidence; extraction uses them, findings inherit the lowest cited confidence, and the eval report shows results by confidence.
- Two lines are merged or split differently from what the model expects: citing is by line number, so the model cannot invent a box.
- The model cites real lines but returns a different text than they contain: the stored finding keeps the model's field values and the cited lines; the mismatch is counted in the eval report as a disagreement.
- A picture is reanalysed after a prompt change: old findings of that picture are replaced by the new run's; the old run is kept as a record until the capture's retention ends.
- A context time zone is invalid or missing: the Mac's zone is used and the capture is flagged.
- The same meeting appears in several captures: each capture keeps its own findings; merging is out of scope (spec 005).
- The user pauses analysis during reading or extraction: the running step finishes; nothing new starts (spec 003).
- Analysis takes long for a busy multi-display capture: the capture shows as queued or analysing in the menu; nothing blocks capturing.
- A golden case has an expected item with a date that depends on the day it is run: cases carry their own capture time, so results do not change with the real date.
- The same meeting is captured from two different applications (for example Outlook and a Teams calendar tab): tags differ, but that alone does not make them different items (FR-029).
- Tags disagree inside one capture (two displays with different applications): each picture has its own tags; the capture has no single set.
- A remote-desktop window shows a different platform look from the host Mac (Windows inside macOS): both are recorded, the remote one as the content's environment.
- Privacy: golden cases from real sessions are never tracked or sent anywhere; eval talks only to the local server.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: After a capture is stored, each display's full-resolution picture MUST be read for text in the background, without blocking capturing or the interface.
- **FR-002**: Every line found MUST be stored with its text, a box in the picture's own pixel coordinates, a confidence, and a number unique and stable within that picture. A picture with no text MUST be recorded as read with zero lines.
- **FR-003**: Reading a picture again MUST NOT create duplicate lines. Lines MUST be deleted together with their capture in every kind of cleanup (spec 002).
- **FR-004**: Each read picture MUST be classified as one of calendar month, calendar week, calendar day, email, chat, document or other. An unsure result MUST be stored as other. The kind, and the instructions and structure versions used for it, MUST be stored.
- **FR-005**: Extraction MUST send the model the analysis copy of the picture and the numbered text lines, use instructions and a required structure chosen by the screen kind, and ask for findings in that structure with a temperature near zero.
- **FR-006**: A finding MUST have a kind (appointment, task, reminder or deadline), a title, and any of: start, end, all-day flag, due date, reminder time, people, place, notes; and it MUST cite the numbers of the lines it comes from. A finding that cites no line, or a line that does not exist in that picture, MUST be discarded and the discard recorded.
- **FR-007**: A task stated as "X needs Y" (and equivalent phrasings the eval set covers) MUST be found as a task for X. A deadline found with an action MUST produce a reminder time when one can be derived.
- **FR-008**: The model's answer MUST be checked against the required structure. A mismatch is a failed attempt handled by the queue's retry rules (spec 003). The raw answer MUST be kept with the run record.
- **FR-009**: Findings MUST be stored per picture, with the model, prompt version, structure version, picture size and the time, and MUST be removed with their capture. Reanalysing a picture MUST replace its findings with the new run's, and MUST keep the earlier run's record and raw answer until the capture is deleted.
- **FR-010**: Dates and times MUST be resolved to full values using, in this order of preference: what the finding shows in full, date headers visible in the view, then the capture time in the context's time zone for relative words. The rule used MUST be recorded. A value that cannot be resolved MUST be stored as written and flagged unresolved.
- **FR-011**: Times MUST be expressed in the time zone of the picture's context, or the Mac's zone when the capture is unassigned or the context has no valid zone.
- **FR-012**: An appointment with a start and no end MUST get an end: from the block height in a calendar view when the block and an hour scale are visible, otherwise one hour after the start. Every guessed value MUST be flagged inferred with its reason (block height or default).
- **FR-013**: Every stored field of a finding MUST be marked as read or inferred, and MUST keep its confidence (the lowest confidence among the cited lines, or lower when inferred).
- **FR-014**: Settings MUST let the user manage contexts: add, rename, delete, set a time zone and edit hints (window title text, domain names, keywords). A default time zone of the Mac is used when none is set.
- **FR-014a**: At capture time, the titles of the windows visible on each display MUST be recorded with that display's picture, stored locally, and deleted together with the capture in every kind of cleanup. They are used only for context matching and MUST NOT be sent anywhere.
- **FR-015**: Each capture's pictures MUST be assigned to the best-matching context automatically, from the text read and the window titles captured with the pictures, and the matched hints and the runner-up MUST be recorded. No match means unassigned.
- **FR-016**: The user MUST be able to change the context of a capture. A user choice MUST be kept across reanalysis and MUST be marked as the user's.
- **FR-017**: Captures MUST be queued for analysis automatically after they are stored, in the same queue as spec 003 (one job at a time, retries, pause, menu progress), unless the user has turned automatic analysis off in Settings. Automatic analysis MUST default to on, regardless of the power source. The menu line MUST keep the texts from spec 003 and count these jobs.
- **FR-018**: Settings MUST show recent captures with their analysis state (waiting, analysing, analysed, failed with reason), screen kind, context, and number of findings, and offer **Reanalyse** for a capture. This is a checking aid; the full Items window is spec 006.
- **FR-019**: A command-line tool `memorri-eval` MUST run the same reading, classification and extraction code as the app over a folder of golden cases and print precision, recall and field accuracy overall and per case, per screen kind, and classification accuracy, with lists of missed and unexpected findings.
- **FR-019a**: `memorri-eval` MUST refuse to start while the app's analysis queue has a job running, telling the user to pause analysis first, because both would load the same model at once. An explicit option MUST allow the run anyway, and the report MUST then say it was run that way.
- **FR-020**: Golden cases MUST each contain a picture, a metadata file (capture time, time zone, optional context hint) and an expected-findings file. Matching a found item to an expected one MUST be defined and documented (same kind; titles at least 80% similar after ignoring case, spaces and punctuation, or one containing the other; and start or due date within 5 minutes; the thresholds are printed in every report); field accuracy MUST be measured on matched items only.
- **FR-021**: `memorri-eval` MUST be able to record a run's results and compare two runs, and MUST accept the picture size, model and prompt version as options.
- **FR-022**: Only synthetic golden cases MAY be tracked in the repository; cases with real content MUST stay untracked. The repository MUST include enough synthetic cases to cover every screen kind, relative dates, header dates, "X needs Y", missing durations and time zone differences.
- **FR-023**: Eval and the app MUST talk only to the local server (spec 003, FR-019). No picture, text or result may leave the Mac.
- **FR-024**: The default analysis picture size MUST be decided from golden-set results at three or more sizes, recorded in an ADR, and applied as the default without overriding a size the user has chosen.
- **FR-025**: The interface MUST stay responsive while reading and extraction run (menu and Settings respond within 1 second).
- **FR-026**: For every analysed picture Memorri MUST record tags about its environment, each with a key, a value, a confidence, and a source (a cited line, a window title, or the look of the picture). The keys MUST include: application, operating system look, remote or virtual desktop session (with client when known), interface language, date format, clock style, theme, visible account or mailbox names and domains, calendar or folder name, time zone labels shown in the view, and the display's pixel size and scale (taken from the capture, not guessed).
- **FR-027**: A tag that cannot be told MUST be absent or marked unknown. A tag judged from the look of the picture alone MUST carry a confidence, and low-confidence tags MUST be marked as such.
- **FR-028**: Each finding MUST keep a copy of its picture's tags as they were for its run, so later steps can compare the environments of two findings. Tags MUST be removed with their capture in every kind of cleanup, because account names and domains can be sensitive, and MUST NOT be sent anywhere.
- **FR-029**: Tags MUST be used as evidence for context detection (FR-015, for example a mailbox domain or a remote-session client matching a context's hints) and MUST inform date reading (clock style, date format, time zone labels). A difference in tags MUST NOT by itself mark two findings as different items; the comparison rule belongs to spec 005, which reads these tags.
- **FR-030**: Settings MUST show a capture's tags in the recent-captures list (FR-018), and `memorri-eval` MUST score tags against expected tags in golden cases (optional per case), reporting accuracy per tag key and listing wrong and missing tags.

### Key Entities

- **Text line**: one line read from a picture: its number within the picture, text, box, confidence.
- **Screen classification**: the kind of screen a picture shows, with the version of the classifier instructions.
- **Finding**: one appointment, task, reminder or deadline found in a picture, with its fields, each marked read or inferred, its cited line numbers, confidence and the run it came from.
- **Analysis run**: one extraction attempt for a picture: model, prompt and structure versions, picture size, timing, outcome and raw answer (an extension of the run record from spec 003).
- **Capture tag**: one fact about the environment a picture shows (application, operating system look, remote session client, language, date format, clock style, theme, visible account or domain, calendar name, time zone label, display size), with value, confidence and source. Findings keep a copy.
- **Context**: a named source (customer, workspace or session) with a time zone and hints.
- **Context assignment**: which context a capture's picture was given, whether automatic or by the user, the matched hints and the runner-up.
- **Golden case**: a picture with its capture time, zone, optional context hint and expected findings, used by eval.
- **Eval report**: precision, recall, field accuracy and classification accuracy for a run, with the settings used.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the tracked synthetic golden set, the shipped settings reach recall of at least 0.85 and precision of at least 0.85 for findings, and field accuracy of at least 0.90 on matched findings.
- **SC-002**: Screen kind classification is correct for at least 90% of synthetic cases, with every supported kind present.
- **SC-003**: At least 95% of the lines in a synthetic picture with known text are read with the exact text, and every stored box overlaps the true text box.
- **SC-004**: 100% of stored findings cite at least one existing line; 0 findings with invalid citations are stored.
- **SC-005**: Every relative-date and header-date case in the golden set resolves to the expected date in the expected zone (100% of those cases), including one captured near midnight in a zone different from the Mac's.
- **SC-006**: Every finding with a guessed end time or date is flagged inferred with its reason (100%), and none of the read values is flagged.
- **SC-007**: For a context with clear hints, at least 95% of synthetic pictures are assigned to it; a user override survives reanalysis in 100% of trials.
- **SC-008**: From a capture being stored to its findings being visible in Settings takes under 3 minutes for a single display with the default settings on the developer Mac, and the menu and Settings stay responsive (under 1 second) throughout.
- **SC-009**: `memorri-eval` on the synthetic set finishes with a report, and running it twice with the same settings gives the same matching of found to expected items (the same model answers are reused or the difference is reported).
- **SC-010**: The picture-size report covers at least three sizes with all measures and time, and records the chosen default and the reason.
- **SC-011**: No real screenshot, capture or model answer is committed, and `lsof` during a run shows connections only to the local machine.
- **SC-012**: On the synthetic set, application, operating system look and clock style tags are correct in at least 90% of cases where the picture shows them; a tag that is wrong is never reported with high confidence more often than once in 20 cases; 100% of stored findings carry their picture's tags.

## Assumptions

- Builds on spec 002 (stored full-resolution and analysis pictures, cleanup, retention) and spec 003 (connection, model choice, durable queue with retries and pause, run records, one network component limited to this Mac). Reconciling the same item across captures is spec 005 and the Items window is spec 006; neither is built here.
- Text reading uses the operating system's built-in recogniser, which runs on the Mac with no server; the model is the local one chosen in spec 003. Both are named in ADR 0004.
- Automatic queueing of captures is new in this spec (spec 003 queued only test jobs). It can be turned off in Settings and defaults to on; the existing pause control still stops it.
- Spec 002 does not record window titles. This spec adds them to the capture step: the titles of the windows visible on each display are stored with its picture (and deleted with it), so context hints can match them. If titles are unavailable, the text read is used alone.
- The kinds of screen are the seven listed; adding a kind later means a new instruction set and structure version, not a redesign.
- Durations default to one hour when nothing else is visible; "end of week" means the last working day (Monday to Friday) of the week, recorded as the rule used. Both can be changed later by versioning the rules.
- The eval tool and the app share the same core code; the tool needs the local server and model running. Golden results depend on model answers, so run-to-run differences are reported rather than hidden.
- Synthetic golden cases are drawn by code (like the built-in sample picture in spec 003), so they contain nothing from real sessions; the user may add real local cases that stay untracked.
- Targets in SC-001 and SC-002 are starting targets for the synthetic set; if the measured evidence shows they are unrealistic, the spec is amended with the reason rather than the set being weakened.
- Findings are stored per picture and replaced on reanalysis; retention is that of the capture (default 7 days), as with raw answers in spec 003. Items a user keeps long term are created by later specs with their own evidence crops.
- Tags are best-effort evidence derived on the Mac from the text read, the window titles and the picture itself; which of them the model sees and which code reads directly is decided in the plan. The key list can grow by adding keys, without a redesign. Tags give spec 005 (reconciliation) its environment evidence; this spec only records them.
- Context hints are matched case-insensitively against text; there is no learning of hints in this spec.
