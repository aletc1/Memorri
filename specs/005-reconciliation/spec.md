# Feature Specification: Turn findings into one list of items without duplicates

**Feature Branch**: `005-reconciliation`

**Created**: 2026-10-01

**Status**: Draft

**Related ADRs**: 0014 (one pipeline, literal text), 0020 (reconciliation, Proposed)

**Input**: User description: "Resolve observations into entities without duplicates: candidate retrieval within the same context and time window, scoring on title prefix/truncation, edit distance, embedding similarity (multilingual-e5) and time overlap, with an LLM or reranker for the uncertain band. Progressive merge with per-field observations and provenance, user field locks, aliases, tombstones for dismissed items, and manual merge/split with undo."

## Clarifications

### Session 2026-10-01

- Q: How far back should undo reach for merges, splits and dismissals? → A: Full history. Every manual and automatic merge, split and dismissal is recorded and can be undone, newest first, with no time limit.
- Q: How close in time must an existing item be to a new sighting to be considered as the same event? → A: Appointments: same calendar day in the context's time zone, with times overlapping or starts within 15 minutes. Tasks and reminders: due dates within 1 day of each other, or both without a date.
- Q: Where should the plain list of items live in this spec? → A: In its own Items window opened from the menu bar; spec 006 extends that window.
- Q: What should happen to the findings already stored from earlier captures when this feature ships? → A: Nothing. Only captures analysed after the update produce items; an older capture produces items when it is reanalysed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The same meeting seen twice is one item (Priority: P1)

The user captures their screen several times a day. The same appointment shows up in a month view, again in a week view, again in a reminder email, and sometimes with a title cut off by a narrow calendar block ("Quarterly planning with the cust…"). Today each sighting is a separate finding. After this feature, every finding is compared with the items Memorri already holds for the same context and time, and sightings of the same real-world event become one item, no matter how many captures or screen kinds showed it.

**Why this priority**: Without it the list grows by a duplicate on every capture and nothing downstream (the Items window, search, Calendar sync) is usable. It is the core of the spec.

**Independent Test**: Analyse several captures that show the same appointments in different views and with truncated titles; the list holds one item per real appointment.

**Acceptance Scenarios**:

1. **Given** an item "Daily standup" on a Tuesday at 09:00, **When** a later capture shows "Daily standup" the same Tuesday at 09:00, **Then** no new item is created and the earlier one gains the new sighting.
2. **Given** an item "Quarterly planning with the customer", **When** a capture shows a block titled "Quarterly planning with the cust…" at the same time, **Then** both are the same item.
3. **Given** two different meetings at the same time in the same context ("Design review" and "Budget review"), **When** both are found, **Then** they stay two items.
4. **Given** the same title in the same context on different days, **When** both are found, **Then** they stay two items (a recurring meeting is one item per occurrence).
5. **Given** the same title and time in two different contexts, **When** both are found, **Then** they stay two items.
6. **Given** a capture is analysed again (same model or another), **When** its findings are reconciled, **Then** no new items appear and the existing ones are not changed except by better information.

---

### User Story 2 - An item gets more complete as more captures arrive (Priority: P1)

A first capture shows only a title and a start time. A later one shows the end time, the place and the attendees. The item keeps every sighting as an observation of each field it showed, with the capture, the lines it came from and a confidence, and its current value for each field is chosen by rule: what the user set, then what was read over what was guessed, then the more confident, then the more recent. A guessed one-hour duration is replaced as soon as a real end time is seen.

**Why this priority**: This is what makes Memorri a second brain rather than a list of snapshots, and it keeps the promise that every field carries its evidence (constitution II).

**Independent Test**: Reconcile two findings of one appointment, the second adding an end time and a place; the item shows both, and each field can be traced to its capture.

**Acceptance Scenarios**:

1. **Given** an item whose end time was guessed, **When** a later finding shows a real end time, **Then** the real one becomes the item's end time and the guess is kept only as history.
2. **Given** an item with a title read in full and a later finding with a truncated title, **When** they merge, **Then** the full title stays the item's title and the truncated one is kept as an alias.
3. **Given** two findings that disagree on a field with similar confidence, **When** they merge, **Then** the more recent one wins and the other stays visible as an earlier observation.
4. **Given** any item, **When** its history is asked for, **Then** each field lists its observations with capture, source lines, confidence and whether it was inferred.

---

### User Story 3 - What the user changes or dismisses stays that way (Priority: P1)

The user edits an item's title, or dismisses an item they do not want. A field the user edited is locked: later captures never overwrite it, though they are still recorded as observations. A dismissed item is remembered, and when the same event is seen again in later captures it does not come back.

**Why this priority**: Constitution IV. If a dismissed item reappears or an edit is overwritten, the user stops trusting the list.

**Independent Test**: Edit a title and dismiss another item, then analyse captures that show both again; the edit stands and the dismissed item stays gone.

**Acceptance Scenarios**:

1. **Given** the user changed an item's title, **When** a later capture shows the old title, **Then** the item keeps the user's title and the new sighting is added as an observation.
2. **Given** a dismissed item, **When** a later capture shows the same event (same context, same time, same or truncated title), **Then** no new item is created.
3. **Given** a dismissed item, **When** a capture shows a clearly different event at the same time, **Then** a new item is created.
4. **Given** a dismissal, **When** the user restores it, **Then** the item is back with its history and later sightings are merged into it again.
5. **Given** a locked field, **When** the user clears the lock, **Then** the field takes the value the rules choose from its observations.

---

### User Story 4 - Fix a wrong merge or a missed one, and undo (Priority: P2)

Memorri sometimes merges two different events or fails to merge two sightings of one. The user can merge two items into one, split a merged item back into the sightings that belong together, and undo any of these operations, including automatic merges, back through the full history. Undo restores items, field values, locks and aliases exactly as they were.

**Why this priority**: Automatic merging will be wrong sometimes (constitution III says merging is reversible). It comes after the automatic behaviour because that is what delivers value; this is the safety net.

**Independent Test**: Merge two items by hand, check the combined history, undo, and see both items back unchanged.

**Acceptance Scenarios**:

1. **Given** two items for one event, **When** the user merges them, **Then** one item remains holding every observation, alias and lock of both, and the other is recorded as merged into it.
2. **Given** a merged item, **When** the user splits off a set of its sightings, **Then** a new item is made from them and each item's fields are recomputed.
3. **Given** a merge or split just made, **When** the user undoes it, **Then** all items, values, locks and aliases are as before.
4. **Given** an automatic merge made days ago, **When** the user undoes it from the item's history, **Then** the two items are restored and later sightings stay with the item they match.
5. **Given** the user split two sightings apart, **When** later captures show them again, **Then** automatic merging does not join them again.
6. **Given** two items that both had locked values for the same field, **When** they are merged, **Then** the user is asked which value to keep, and the choice is recorded.

---

### User Story 5 - See the result and measure it (Priority: P2)

The user can see the list of items Memorri holds, each with its kind, title, times, context and number of sightings, in an Items window opened from the menu bar, and can use the manual actions above from there. The developer can run the evaluation tool on a set of cases made of several sightings of the same events and read how many true duplicates were merged and how many different events were wrongly merged.

**Why this priority**: The app must stay runnable and testable after each spec (constitution VII) and prompt or matching changes must be measured (constitution VI). The full Items window with evidence crops is spec 006; this story only gives the minimum to try and judge reconciliation.

**Independent Test**: Run the evaluation tool on the duplicate set and read the two measures; open the list in the app after analysing a few captures.

**Acceptance Scenarios**:

1. **Given** items exist, **When** the user opens the Items window from the menu bar, **Then** each item shows its kind, title, time, context and the number of captures that showed it.
2. **Given** an item, **When** the user opens its details, **Then** its observations, aliases, locks and merge history are shown.
3. **Given** a set of golden cases with known duplicates, **When** the developer runs the evaluation, **Then** the report shows the share of duplicates merged and the share of wrong merges, per case and overall.
4. **Given** the matching rules change, **When** the evaluation is run again, **Then** it can be compared with an earlier report.

---

### Edge Cases

- An appointment whose date could not be resolved: it is compared like an undated task (strong title match, same context), so it does not repeat on every capture.
- A finding with no time at all (a task with no due date): it is compared by title and context only and is merged only on a strong title match.
- Two findings whose time overlaps only partly (09:00-10:00 and 09:30-10:30) with near-identical titles: merged; with different titles: kept apart.
- A title in another language or with different accents or case: still matched.
- A capture whose findings all match items already held: nothing new is created and the capture is recorded as having added no items.
- An item seen in one view as all-day and in another with a time: merged when the day and title match, the timed value wins as the more specific one.
- A time that moved (the same meeting seen at 09:00 earlier and 10:00 now): this spec keeps both as separate items and does not guess a reschedule; changes of time are handled later.
- Two findings in the same capture that are themselves duplicates (the same block read twice): merged before anything else.
- The step that decides uncertain cases is unavailable or times out: the pair is kept as separate items and marked for review, and no capture fails because of it.
- Undo after later captures were reconciled into the merged item: the undo splits out only what the operation joined and leaves later sightings with the item they would now match.
- Thousands of items: finding candidates stays quick because only items of the same context and nearby time are looked at.
- A dismissed item whose event is seen at a different time or with a very different title: treated as a new event.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: After a capture has been analysed, each of its findings MUST be reconciled with the items already held, and each finding ends up as an observation of exactly one item (new or existing).
- **FR-001a**: Findings stored before this feature MUST NOT be reconciled automatically; a capture analysed before it produces items only when it is analysed again.
- **FR-002**: Candidates for a finding MUST be limited to items of the same context, of the same kind family (appointment with appointment, task, reminder or deadline with task, reminder or deadline), and close in time to the finding: for appointments, the same calendar day in the context's time zone with times overlapping or starts within 15 minutes (an all-day sighting matches any time that day); for tasks and reminders, due dates within 1 day of each other, or both without a date.
- **FR-003**: A candidate MUST be scored from the similarity of titles (accounting for truncation, prefixes, case, accents and small spelling differences), the overlap of times, and the closeness of meaning of the titles across languages.
- **FR-004**: A score above the upper threshold MUST merge the finding into the candidate; a score below the lower threshold MUST create a new item; a score in between MUST be decided by a second, slower judgment, and if that judgment is unavailable the finding MUST become a new item flagged as a possible duplicate.
- **FR-005**: Reconciliation MUST be repeatable: analysing the same capture again MUST NOT create items; the item's fields reflect the latest analysis of each picture (comparing analyses before applying one belongs to the reprocessing spec).
- **FR-006**: Every field of an item MUST be backed by its observations, each recording the capture, the source lines, the confidence and whether the value was inferred.
- **FR-007**: An item's current value for each field MUST be chosen by this order: user-set value, then read over inferred, then higher confidence, then more complete, then more recent.
- **FR-008**: The full, non-truncated title MUST be preferred as the item's title; other titles seen MUST be kept as aliases and used in later matching.
- **FR-009**: A field edited by the user MUST be locked; later observations MUST be recorded but never change a locked field; the user MUST be able to unlock it.
- **FR-010**: A dismissed item MUST be remembered so the same event seen later (same context, matching time and title, including truncated titles) is not recreated; the user MUST be able to restore it.
- **FR-011**: The user MUST be able to merge two items, split sightings out of an item, and undo any recorded merge (manual or automatic), split or dismissal, with no time limit; when later operations touched the same items the undo is partial and says so; each operation MUST be recorded with enough detail to be undone exactly.
- **FR-012**: A split performed by the user MUST prevent automatic reconciliation from joining the same sightings again.
- **FR-013**: When items with conflicting locked fields are merged, the user MUST choose which value to keep.
- **FR-014**: Removing a capture (by any kind of cleanup) MUST remove its sightings and their observations; an item left with no sightings MUST be removed, unless the user edited, locked or dismissed it, and the item's fields MUST be recomputed from what remains.
- **FR-015**: The app MUST show, in an Items window opened from the menu bar, the list of items with kind, title, time, context and number of sightings, and offer merge, split, dismiss, restore and undo from it, plus a view of an item's observations, aliases and locks.
- **FR-016**: The evaluation tool MUST be able to score reconciliation on golden cases made of several sightings of the same events, reporting the share of duplicates merged and the share of wrong merges, and MUST support comparing two runs.
- **FR-017**: Reconciliation MUST use only models and services on this Mac, and MUST NOT send captured content anywhere else.
- **FR-018**: Reconciliation MUST finish for the findings of one capture without making analysis of the next capture wait noticeably, and MUST never fail a capture's analysis.
- **FR-019**: Every automatic merge MUST record why it was made (the scores) so a wrong merge can be understood.

### Key Entities

- **Item**: One real-world appointment, task or reminder. Has a kind, a status (active, dismissed, or merged into another item), a context, current values for title, start, end, all-day, due, reminder time, people, place and notes, and links to its observations. Made from one or more findings.
- **Observation**: One sighting of one field of an item: the value as found, the capture and source lines it came from, a confidence, whether it was inferred, and when it was seen.
- **Alias**: Another title an item has been seen with, including truncated forms, used in matching.
- **Field lock**: Marks a field the user set; later observations are recorded but do not change it.
- **Tombstone**: A dismissed item kept with its context, time and titles, so the same event is attached to it instead of recreated.
- **Merge record**: A record of one automatic or manual merge or split with the scores or reason, and everything needed to undo it.
- **Possible duplicate**: A pair of items the automatic judgment could not decide, kept for the user to merge or confirm apart.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the duplicate golden set, at least 95% of true duplicates (same event seen in several captures, views, languages or with truncated titles) end as one item.
- **SC-002**: On the same set, at most 2% of items contain sightings of different events.
- **SC-003**: Analysing any stored capture a second time creates zero new items.
- **SC-004**: After merging and then undoing, or splitting and then undoing, every item, field value, lock and alias equals what it was before, in every tested case.
- **SC-005**: A field the user edited keeps the user's value through 100% of later captures in the test cases, and a dismissed event is not recreated in 100% of them.
- **SC-006**: Reconciling the findings of one capture adds less than 2 seconds on average when the slower judgment is not needed, and the slower judgment is needed for fewer than 10% of compared pairs on the golden set.
- **SC-007**: After analysing the 27 synthetic captures once, then again, the list holds no more items than the distinct events they contain, and the user can see the date, time and display of any item's source captures from the app in two actions or fewer.
- **SC-008**: Every merged item can show why it was merged and every field can show its sightings, in 100% of the test cases.

## Assumptions

- Findings stored before this feature are left as they are; reanalysing such a capture reconciles it.
- Findings come from the analysis of spec 004; reconciliation starts after a capture's analysis is stored and does not change how findings are read.
- Contexts are those of spec 004; each finding's context is the one assigned to its capture.
- A recurring meeting is one item per occurrence; recognising series is out of scope.
- Rescheduled events are not detected here; a moved meeting is a new item and the older one stays until the user dismisses it. Cancellation and rescheduling are handled in the hardening spec.
- Confidence-gated approval, the Inbox, evidence crops and the full Items window are spec 006; this spec shows only a plain Items window with the manual actions needed to try and correct reconciliation.
- Syncing to Calendar and Reminders is spec 009 and is not touched here.
- Reprocessing with a new model or prompt and comparing results is spec 008; reconciliation here must already be safe to run on a capture twice.
- The models used for meaning and for the uncertain band are local and are the ones already planned for deduplication; if they are not installed, reconciliation still works on text and time alone and flags uncertain pairs.
- SC-001 applies with the matching models installed; without them translated titles are flagged as possible duplicates instead of merged.
- Thresholds start as defaults chosen on the golden set and are not user settings.
- The golden set for duplicates is synthetic and tracked; real captures stay untracked as before.
- Dismissal and field editing arrive in the UI with spec 006; here they exist as operations in the list and in tests, and the list offers dismiss and edit-title as the minimum way to exercise locks and tombstones.
