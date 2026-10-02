# Feature Specification: Reprocess captures and compare before applying

**Feature Branch**: `008-reprocessing`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0005 (Ollama calls), 0014 (dates resolved in code), 0019 (default model), 0020 (items), 0022 (window-aware analysis)

**Input**: User description: "Re-run stored captures with a new model or prompt version, compare the results against the current items, apply the selected changes, and keep an audit trail." (roadmap 008). Specs 004, 005, 006 and 011 already analyse captures, reconcile them into items, let the user edit, approve and dismiss, and re-read the whole library once after an update.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Try another model or prompt on stored captures without touching my items (Priority: P1)
The user picks a set of stored captures and a way to read them (the current model, another installed model, or the newest prompt version) and starts a trial. The trial reads the captures again in the background at low priority, behind new captures. Nothing about the user's items changes while it runs or after it ends: its results are kept as proposals, labelled with the model, the prompt version and the date.

**Why this priority**: changing the model or a prompt today means re-reading everything blind. A trial that cannot damage the library makes it safe to compare, and it is the base of everything else here.

**Independent Test**: Start a trial on five captures with a different model. The Items window, Inbox counts, approvals and edits are identical before, during and after; the trial's progress shows (`3 of 5 read`); it can be cancelled and resumed after a restart; the proposals are listed with their model and prompt version.

**Acceptance Scenarios**:
1. **Given** stored captures whose pictures are kept, **When** the user starts a trial with a chosen model and prompt version on a chosen set, **Then** a trial is created, queued behind new captures, and shows progress.
2. **Given** a trial is running, **When** a new capture arrives, **Then** the new capture is analysed first and the trial continues afterwards.
3. **Given** a trial is running, **When** the user cancels it or quits the app, **Then** the results read so far are kept and the rest can be resumed later, and the user's items are unchanged.
4. **Given** a capture whose picture was deleted, **When** a trial includes it, **Then** it is skipped and counted as skipped, not failed.
5. **Given** the chosen model is not installed or the server is down, **When** the user starts a trial, **Then** it explains why and nothing is queued.

---

### User Story 2 - See what would change before anything changes (Priority: P1)
When a trial finishes (or has partial results), the user opens its comparison. It sums up the trial (captures read, items that would be created, changed, no longer found, unchanged, flagged for review) and lists the differences capture by capture and item by item: a new item, a different time, a different title, an item the trial did not find, a field the user edited that the trial disagrees with. Each difference shows the current value, the proposed value, the evidence (the cut-out of the capture) and the confidence.

**Why this priority**: without a comparison a trial is just a black box; the user needs the evidence to decide.

**Independent Test**: With a trial of known differences (one added item, one moved time, one missing item, one user-edited field), open the comparison: each is listed once with current and proposed values; user-edited, locked, approved and dismissed items are marked as protected; counts add up to the totals.

**Acceptance Scenarios**:
1. **Given** a finished trial, **When** the user opens it, **Then** the totals and the list of differences appear, grouped by capture and by item.
2. **Given** a difference on a field the user edited or locked, **When** shown, **Then** it is marked `You set this` and cannot be applied.
3. **Given** a dismissed item, **When** a trial finds it again, **Then** it is shown as dismissed and never proposed as new.
4. **Given** an item the trial did not find, **When** shown, **Then** it is listed as `Not found in this trial`, with its evidence, and is never removed by applying.
5. **Given** two trials of different models on the same captures, **When** the user compares them, **Then** each difference between the two trials is shown next to the current items.

---

### User Story 3 - Apply the changes I choose and keep an audit trail (Priority: P2)
The user selects differences (one, a capture's, an item's, or everything not protected) and applies them. Applying updates the items through the normal reconciliation (new sightings replace the old ones of that capture; new items are created; matching, merging and the Inbox rules are the same as for a new capture), never overwrites a user-set value, and can be undone as one operation. Every apply and every trial is written to an audit trail: when, which model and prompt version, which captures, what changed, who chose it.

**Why this priority**: it makes the trial useful; builds on stories 1 and 2.

**Independent Test**: Apply two differences from a trial: the two items change, nothing else does, user-edited fields are untouched, the items show the new sighting with the trial's model in their history, the audit trail has one entry, and Undo restores the previous values and sightings.

**Acceptance Scenarios**:
1. **Given** selected differences, **When** the user applies them, **Then** only those items change, through the same reconciliation as a new capture, and the Inbox rules run again on them.
2. **Given** applied changes, **When** the user chooses Undo last (or Undo on the audit entry), **Then** the items return to their previous values, sightings and review state.
3. **Given** applying twice the same selection, **When** the second apply runs, **Then** nothing changes and no duplicate items or sightings appear.
4. **Given** the audit trail, **When** the user opens it, **Then** each trial and each apply is listed with date, model, prompt version, number of captures, counts of changes and whether it was undone; an item's history shows which trial changed it.
5. **Given** an item the user edited, locked, approved or dismissed, **When** a selection that includes it is applied, **Then** the user's values stay and the item is reported as skipped with the reason.

---

### User Story 4 - Know when the library was read with something older (Priority: P3)
The app shows how many stored captures were last read with a model or prompt version other than the current ones, so the user can decide to run a trial on them. Nothing is queued automatically.

**Why this priority**: it connects a prompt or model change to the trial that follows; useful but optional.

**Independent Test**: After changing the model in Settings, the Reprocess area says `12 captures were read with another model or prompt` and offers to start a trial on them.

**Acceptance Scenarios**:
1. **Given** captures read with an older model or prompt version, **When** the user opens the Reprocess area, **Then** the count and a button that selects exactly those captures appear.
2. **Given** every capture was read with the current model and prompt, **When** it opens, **Then** it says nothing is out of date.

---

### Edge Cases

- A trial of a capture produces no findings: the comparison lists the current items of that capture as `Not found in this trial`; nothing is removed.
- The model fails on some captures (timeout, bad output): the capture is marked failed in the trial with the reason, the rest continue, and failed captures can be retried.
- A capture analysed again while a trial holds its proposal: the proposal shows as out of date and can be refreshed or discarded.
- An item changed (edited, merged, split, dismissed) after the trial ran: the difference is checked again at apply time and skipped with a reason if it no longer holds.
- Many trials pile up: the user can delete a trial; deleting a trial never changes items or the audit trail.
- A trial on 1,000 captures runs for hours: the app stays responsive, the queue order is kept, progress and a cancel button remain available.
- Picture retention: applying needs no picture; only running a trial does.
- Search, the Inbox and the calendar always show items, never proposals.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The user MUST be able to start a trial on a chosen set of stored captures with a chosen model and prompt version; the choices default to the current ones.
- **FR-002**: A trial MUST never change items, sightings, evidence, approvals or the Inbox; its results are stored apart as proposals labelled with model, prompt version and time.
- **FR-003**: Trials MUST run in the background behind new captures and other queued work, show progress, be cancelable, and resume after a restart; partial results MUST be kept.
- **FR-004**: Captures whose picture is gone MUST be skipped and counted as skipped; failures MUST be recorded per capture with a reason and be retryable.
- **FR-005**: The comparison MUST show totals (created, changed, not found, unchanged, protected, flagged for review) and a list of differences by capture and by item, each with current value, proposed value, evidence and confidence.
- **FR-006**: Differences on a field the user edited or locked, and on items the user approved or dismissed, MUST be shown as protected and MUST NOT be applicable; a dismissed item MUST NOT be proposed as new.
- **FR-007**: The user MUST be able to apply one difference, all differences of a capture or of an item, or all that are not protected.
- **FR-008**: Applying MUST go through the same reconciliation, Inbox rules and locks as a new capture, MUST be idempotent (no duplicate items or sightings when repeated) and MUST be one undoable operation.
- **FR-009**: Items the trial did not find MUST be reported as such and MUST NOT be removed or changed by applying.
- **FR-010**: Differences MUST be checked again when applied; those that no longer hold MUST be skipped with a reason.
- **FR-011**: Every trial and every apply MUST be written to an audit trail with time, model, prompt version, captures, counts and outcome (including undone); an item's history MUST show the trial that changed it.
- **FR-012**: The user MUST be able to compare two trials of the same captures and to delete a trial without affecting items or the audit trail.
- **FR-013**: The app MUST show how many stored captures were last read with a different model or prompt version and offer to select them; it MUST NOT queue anything automatically.
- **FR-014**: Starting a trial MUST check that the model is installed and the server reachable, and say why when it is not.
- **FR-015**: All of it MUST stay on this Mac (no network beyond the local Ollama), and a change of prompt or model that ships with this spec MUST pass the eval harness as required by the constitution.
- **FR-016**: The reprocessing interface MUST be reachable from [NEEDS CLARIFICATION: where does the Reprocess area live: its own window opened from the menu, a section of Settings > Analysis, or a mode of the Items window?].
- **FR-017**: The set of captures for a trial MUST be chosen by [NEEDS CLARIFICATION: which ways of choosing captures are in scope: all stored, a date range, a context, only those read with another model or prompt, or one capture opened from the capture viewer?].

### Key Entities

- **Trial**: one run of a model and prompt version over a set of captures: id, model, prompt version, created, state (queued, running, finished, cancelled), counts.
- **Proposal**: what a trial read from one capture (the findings with their cited lines and confidence), kept apart from items.
- **Difference**: a proposed change against a current item (new item, changed field, not found, protected), with current and proposed values, evidence and status (open, applied, skipped, out of date).
- **Audit entry**: a record of a trial or an apply: when, model, prompt version, captures, counts, outcome, undone or not.
- **Read marker**: which model and prompt version last read each capture, for the out-of-date count.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Before, during and after a trial, 100% of items, sightings, approvals and Inbox counts are unchanged (checked by comparing the whole library before and after).
- **SC-002**: 100% of differences on user-edited, locked, approved or dismissed items are shown as protected and 0 of them change when everything is applied (checked on a library with every kind of protection).
- **SC-003**: Applying the same selection twice leaves the library identical to applying it once (no duplicate items or sightings).
- **SC-004**: Undoing an apply restores 100% of the affected items' values, sightings and review state.
- **SC-005**: Every trial and apply appears in the audit trail within one second of finishing, with the right counts.
- **SC-006**: New captures are analysed within the same time as without a running trial (a trial never delays one; checked in the queue tests).
- **SC-007**: A trial interrupted by a restart resumes with no capture read twice and none lost.
- **SC-008**: A user finds the differences of a trial and applies one in at most three actions from the Reprocess area.

## Assumptions

- A trial reuses the existing analysis pipeline (OCR text kept, windows, extraction) and only changes the model and the prompt version; it does not recapture or re-run OCR when the stored text is current.
- Proposals are derived data and can be deleted at any time; deleting them frees disk and never changes items.
- The user's edited, locked, approved or dismissed values always win, as in specs 005 and 006.
- The one-off library re-read of spec 011 stays as it is; it is not replaced by trials.
- Changing the default model or prompt itself stays in Settings; this spec only makes the effect testable.
- Comparing the pipeline on the golden set stays the job of `memorri-eval` (spec 004); this spec compares on the user's own stored captures, inside the app.
- Out of scope: auto-applying results, scheduling trials, syncing to Calendar or Reminders (spec 009), and comparing more than two trials at once.
