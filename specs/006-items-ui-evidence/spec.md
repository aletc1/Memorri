# Feature Specification: See where every item comes from, fix it in place, and review the doubtful ones

**Feature Branch**: `006-items-ui-evidence`

**Created**: 2026-10-01

**Status**: Draft

**Related ADRs**: 0020 (reconciliation: items, sightings and the operation log)

**Input**: User description: "An Items window for Appointments, Tasks and Reminders filtered by context. Detail view shows evidence crops and field provenance. Inline edits lock fields. An Inbox lists low-confidence items for approve or dismiss. (Spec 005 already ships a minimal Items window with filters, list, detail with fields, sightings and history, merge, split, dismiss, restore, title edit, unlock and undo; this spec grows it: cropped evidence from the cited OCR lines of each sighting, per-field provenance and inline editing of every field with locking, and the confidence-gated Inbox.)"

## Clarifications

### Session 2026-10-01

- Q: Below what confidence should an item go to the Inbox for review, and can you change that level? → A: 0.75, fixed. Below 0.75, or with a guessed time, an item needs review; it is not a setting.
- Q: Should evidence cut-outs be saved to disk, or cut from the stored picture each time you open an item? → A: Saved when the capture is analysed, as small files counted in the storage figures.
- Q: When a later capture conflicts with an item you already approved, what should happen? → A: Unlocked values update as usual and the item returns to the Inbox with the reason "changed after you approved it".
- Q: When a capture is deleted (by the user or by retention), should its cut-outs be deleted too? → A: No. Cut-outs stay as long as the item they prove exists; "Delete everything" in Storage still removes them.
- Q: How many sightings should an item's detail show before a "Show all" button? → A: The 5 newest, then "Show all N sightings".

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Show me the proof (Priority: P1)

The user opens an item and wants to know whether to trust it. Today the detail view says where a value came from in words (a capture date, a display, a confidence). They want to *see* it: the part of the screenshot where the title, the time or the place was read, cut out of the picture next to the value, and, when that is not enough, the whole picture with that part marked.

**Why this priority**: The app guesses from screenshots, so trust depends on checking the guess against the source. Every other part of this spec (reviewing the doubtful ones, editing a wrong value) starts from looking at the evidence.

**Independent Test**: Analyse a synthetic capture, open an item from it, and see for each field the cut-out of the lines it was read from; open the whole picture from a sighting and see the cited lines marked.

**Acceptance Scenarios**:

1. **Given** an item seen in one capture, **When** the user opens it, **Then** each sighting shows a cut-out of the picture around the lines the finding cited, with the capture date, time and display beside it.
2. **Given** an item seen in three captures, **When** the user opens it, **Then** the sightings are listed newest first, each with its own cut-out, and the user can tell which sighting each field value was taken from.
3. **Given** a sighting's cut-out, **When** the user asks to see the whole capture, **Then** the picture opens with the cited lines marked, and closing it returns to the item.
4. **Given** a capture whose pictures were deleted by cleanup or retention, **When** the user opens an item that was seen in it, **Then** the sighting still shows its saved cut-out, text and details; asking for the whole capture says the picture is no longer stored, and nothing else in the item breaks.
5. **Given** a sighting that cited no readable lines (the model inferred the value), **When** the user opens it, **Then** it says there is no cut-out for it and why, instead of showing an empty box.

---

### User Story 2 - Review the doubtful ones in an Inbox (Priority: P1)

Most items are read clearly and need no attention. A few are doubtful: a time that was guessed, a title the model barely made out, a single faint sighting. The user wants those collected in one place, the Inbox, where each can be checked against its evidence and either approved (this is right) or dismissed (this is not a real item). Items that are not doubtful never appear there and count as approved.

**Why this priority**: This is the confidence gate. Spec 009 will sync to Calendar and Reminders only what is approved, so without the Inbox either wrong items sync or nothing does. It also keeps the user's attention on the few items that need it.

**Independent Test**: Analyse a set of synthetic captures that gives both clear and doubtful items; the Inbox lists only the doubtful ones, approving moves one out and keeps it in the Items window, dismissing one follows the existing dismissal rules.

**Acceptance Scenarios**:

1. **Given** items found with high confidence and read (not guessed) times, **When** the user opens the Inbox, **Then** they are not listed and show as approved in the Items window.
2. **Given** an item whose confidence is below the review level, or whose start, due or end time was guessed, **When** the user opens the Inbox, **Then** it is listed with the reason it needs review.
3. **Given** an item in the Inbox, **When** the user approves it, **Then** it leaves the Inbox, shows as approved, and stays approved when later sightings arrive.
4. **Given** an item in the Inbox, **When** the user dismisses it, **Then** it leaves the Inbox and is dismissed with the same rules and undo as a dismissal from the Items window.
5. **Given** an approved item, **When** a later capture shows a conflicting time, **Then** the item returns to the Inbox with the reason "changed after you approved it" and keeps its approval history.
6. **Given** the user edits a field of an item in the Inbox, **When** the edit is saved, **Then** the item counts as approved, because the user has checked it.
7. **Given** the Inbox is empty, **When** the user opens it, **Then** it says nothing needs review.
8. **Given** an approval or a dismissal made in the Inbox, **When** the user chooses Undo last, **Then** it is undone like any other operation.

---

### User Story 3 - Fix any field where I see it (Priority: P2)

A time is an hour off, a place is missing, the people list is wrong. The user wants to correct any field of an item directly in its detail view, without leaving it, and to know the correction will not be undone by the next capture. Today only the title can be edited.

**Why this priority**: Evidence (story 1) shows what is wrong; editing is how the user fixes it. It builds on rules that already exist (a user value is locked and beats later sightings), so the work is mostly in the view.

**Independent Test**: Open an item, change its start time, place, people and notes in place, analyse another capture that shows the old values, and confirm the user's values remain and show as locked.

**Acceptance Scenarios**:

1. **Given** an item, **When** the user edits its title, start, end, all-day, due, reminder time, people, place or notes in the detail view and confirms, **Then** the new value is shown at once with the source "you" and a lock.
2. **Given** a locked field, **When** later captures show another value, **Then** the user's value stays, and the other values remain visible as sightings of that field.
3. **Given** a locked field, **When** the user unlocks it, **Then** the value goes back to the one the sightings decide, and the user can see which that is.
4. **Given** a date or time field, **When** the user enters something that is not a valid date, **Then** the edit is rejected with a message in place, and the old value stays.
5. **Given** a start time later than the end time, **When** the user confirms, **Then** the edit is rejected with a message that says why.
6. **Given** an edit, **When** the user chooses Undo last, **Then** the field returns to what it was, with its lock state.
7. **Given** a field with no value (for example no place), **When** the user adds one, **Then** it is stored as the user's value and locked like any other edit.

---

### User Story 4 - Browse by kind and context, and see what matters at a glance (Priority: P3)

The user wants the Items window to match how they think: appointments, tasks and reminders as separate kinds, filtered by the customer or workspace (the context) the item came from, with a clear sign of which items need review and which were approved.

**Why this priority**: Spec 005's window already filters by kind (appointments or tasks and reminders together) and context. This refines it, and it matters only once the Inbox and approval exist.

**Independent Test**: With items of all three kinds in two contexts, each filter combination lists exactly the expected items, and the window shows the review count.

**Acceptance Scenarios**:

1. **Given** appointments, tasks and reminders, **When** the user picks Reminders, **Then** only reminders are listed (and likewise for Appointments and Tasks).
2. **Given** items in two contexts, **When** the user picks one context, **Then** only its items are listed, and the Inbox can be limited to a context the same way.
3. **Given** items needing review, **When** the user looks at the menu and the window, **Then** both show how many need review, and the number matches the Inbox.
4. **Given** a list of items, **When** the user looks at a row, **Then** it shows the kind, title, date and time, context, approval state and whether any field is locked.

---

### Edge Cases

- A sighting cites lines on a picture that has more than one display or was captured at a different size than the model saw: the cut-out must still match the lines it claims (it is made from the full-size picture, not from the downscaled copy).
- A cited line sits at the very edge of the picture: the cut-out is cropped to the picture, not padded with empty space.
- An item has dozens of sightings (a recurring view captured all day): the detail view shows the 5 newest with their cut-outs and a "Show all N sightings" button, and stays responsive.
- A picture is deleted while the user has the item open: the saved cut-out stays; opening the whole capture shows the "no longer stored" notice without an error.
- An item is removed (its sightings all gone and it was never touched by the user) or the user chooses "Delete everything": its cut-outs are removed with it.
- Two edits to the same field in a row, or an edit made while a capture is being reconciled: the last confirmed edit wins and nothing is lost; undo still goes back one step at a time.
- The user approves an item and later merges it with another: the merged item is approved only if both were; otherwise it returns to the Inbox with the reason.
- An item split from an approved item starts out not approved if its own sightings are doubtful.
- Inline edit of a date in a time zone different from the Mac's: the date is read and shown in the item's own zone.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The detail view MUST show, for every sighting of an item, a cut-out of the capture around the lines that sighting cited, with the capture date, time and display.
- **FR-002**: The user MUST be able to open the whole capture of a sighting with its cited lines marked, and return to the item.
- **FR-003**: Cut-outs MUST be made from the full-size picture when the capture is analysed and saved, MUST match the cited lines, and MUST NOT leave the Mac or be sent to any service.
- **FR-004**: When the full picture of a sighting is no longer stored, the sighting MUST still show its saved cut-out and say the whole capture is gone; when the sighting cited no lines, it MUST say there is no cut-out and why. Either way its text and details stay.
- **FR-004a**: Saved cut-outs MUST be counted in the storage figures, MUST be kept as long as the item they belong to exists (also after the capture is deleted by the user or by retention), and MUST be removed with the item and by "Delete everything".
- **FR-004b**: The detail view MUST show the 5 newest sightings with their cut-outs and a "Show all N sightings" control for the rest.
- **FR-005**: For each field the detail view MUST show the current value, whether it was read, guessed or set by the user, whether it is locked, and the sightings and values behind it; the user MUST be able to see which sighting the current value came from.
- **FR-006**: The user MUST be able to edit every field of an item inline: title, start, end, all-day, due, reminder time, people, place and notes. Each confirmed edit MUST become the user's locked value.
- **FR-007**: Edits MUST be validated before they are stored (valid dates and times, start not after end, a title that is not empty); a rejected edit MUST show why next to the field and MUST keep the old value.
- **FR-008**: A locked field MUST keep the user's value through later sightings, merges and reanalysis, and the user MUST be able to unlock it; unlocking MUST show the value the sightings decide.
- **FR-009**: Every edit, unlock, approval and dismissal made from the new views MUST be recorded in the operation log and be undoable with Undo last, like the operations of spec 005.
- **FR-010**: An item MUST need review when its confidence is below the review level of 0.75 (fixed, not a setting), or when its start, due or end time was guessed rather than read, or when it is a possible duplicate that nobody has decided, or when something changed after the user approved it.
- **FR-011**: The Inbox MUST list exactly the items that need review, each with the reasons, and MUST be usable from the menu bar menu and from the Items window.
- **FR-012**: The user MUST be able to approve an item (it leaves the Inbox and stays approved while nothing conflicts with it) or dismiss it (with the existing dismissal rules).
- **FR-013**: An item that does not need review MUST count as approved without any action, and MUST be shown as approved.
- **FR-014**: An item the user edited MUST count as approved, because the user has checked it.
- **FR-015**: A later sighting that changes an approved item's unlocked values MUST update them as usual and return the item to the Inbox with the reason "changed after you approved it"; it MUST NOT change locked fields.
- **FR-016**: The Items window MUST filter by kind (All, Appointments, Tasks, Reminders), by context (including none) and by approval state, and the Inbox MUST support the context filter.
- **FR-017**: The menu bar menu and the Items window MUST show the number of items needing review, and it MUST equal the number listed in the Inbox.
- **FR-018**: Each list row MUST show the kind, title, date and time in the item's zone, context, approval state, and a lock mark when any field is locked.
- **FR-019**: All views MUST work with the keyboard and carry accessibility labels, and MUST not lose the user's selection when the list updates after a new capture.
- **FR-020**: Opening an item, its cut-outs and the Inbox MUST feel immediate on a library of thousands of items (see the success criteria).

### Key Entities

- **Evidence**: The visual proof of one sighting: a saved cut-out of the capture around the lines the finding cited (kept while its item exists), the full capture with those lines marked while the capture is stored, and the capture's date, time and display. The cut-out is missing only when no lines were cited, and says so.
- **Provenance**: For one field of one item, the current value, how it was obtained (read, guessed, set by the user), whether it is locked, and the sightings and values behind it.
- **Review state**: Whether an item needs review (with the reasons) or is approved, and the history of approvals. It is derived from confidence, guessed fields, undecided possible duplicates and the user's actions.
- **Approval**: The user's decision that an item is right. It is an operation in the log and can be undone.
- **Review level**: The confidence below which an item needs review: 0.75, fixed.
- **Inbox**: The list of items that need review.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For 100% of sightings in the synthetic test set whose picture is stored and which cited lines, the cut-out contains every cited line, and for 0% does it contain lines the sighting did not cite beyond a small margin.
- **SC-002**: From the Items window, a user can see the cut-out and the capture time of the source of any item's current title in two actions or fewer.
- **SC-003**: On the synthetic test set, the Inbox lists every item with a guessed time or low confidence and none of the clear items, and the count in the menu equals the count in the list in 100% of states tested.
- **SC-004**: A user can clear an Inbox of ten items (approve or dismiss each, with the evidence in view) in under two minutes.
- **SC-005**: After editing any field of an item and analysing further captures that show other values, the user's value is still shown in 100% of the tested cases, and unlocking restores the sightings' value in 100% of them.
- **SC-006**: 100% of edits, unlocks, approvals and dismissals from the new views are undone exactly by Undo last in the tested cases (item, fields, locks and approval equal what they were before).
- **SC-007**: With 5,000 items and 20,000 sightings, opening an item with its cut-outs takes under one second, and opening the Inbox takes under half a second.
- **SC-008**: Every one of the tested rejected edits (invalid date, start after end, empty title) leaves the stored value unchanged and shows a message beside the field.

## Assumptions

- Spec 005's items, sightings, observations, locks, aliases, possible duplicates and operation log are the data this spec shows and edits; the rules for merging and for choosing field values do not change.
- A finding's cited lines (spec 004) and the stored text lines of its capture with their positions are available for cut-outs; full-size pictures are kept under the retention rules of spec 002 and may have been deleted.
- Cut-outs are made on this Mac from the full-size picture when a capture is analysed and saved as small files; they count in the storage figures and are under the user's control through "Delete everything" (the constitution's principle V). They deliberately outlive their capture so the evidence stays while the item exists. Sightings made before this spec get their cut-outs once, from the full picture if it is still stored.
- The review level is 0.75 and is not a user setting in this spec; if it changes in a later version, earlier approvals stay.
- "Guessed" means the finding flagged the value as inferred (for example an end time from a default duration), as in spec 004.
- Approval is stored per item and is what Calendar and Reminders sync (spec 009) will read; nothing is synced here.
- Search (spec 007), reprocessing with a new model (spec 008), cancellation detection and notifications (spec 010) are out of scope; the Inbox is built so that spec 010 can add items "possibly cancelled" to it.
- Items still come from analysed captures only; findings stored before spec 005 are not shown until their capture is analysed again.
- The Items window keeps the actions of spec 005 (merge, split, dismiss, restore, undo); this spec adds to them and does not remove any.
