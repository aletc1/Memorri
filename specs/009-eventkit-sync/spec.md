# Feature Specification: Sync items to Calendar and Reminders

**Feature Branch**: `009-eventkit-sync`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0006 (EventKit sync targets), 0020 (items), 0021 (evidence and review state), 0025 (trials)

**Input**: User description: "Request Calendar and Reminders access, pick a target calendar and a target reminders list, and upsert one-way through sync_links (ADR 0006). Include context in titles, evidence and a deep link in notes, detect edits made in Calendar.app and lock those fields, and offer a dry-run mode. Only confident items sync automatically." (roadmap 009). Specs 005 to 008 already keep items with sightings, evidence, locks, an Inbox with approval, search and reprocessing. The Settings window already has a placeholder "Calendar sync" tab.

## Clarifications

### Session 2026-10-02

- Q: When does sync run? → A: Automatically, soon after an item becomes ready or changes and when the app starts; `Preview` and `Sync now` stay available.
- Q: What happens in Calendar and Reminders when an item is dismissed or merged away? → A: The entry Memorri made is removed; restoring the item writes it again.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Choose where items go and allow access (Priority: P1)
In Settings > Calendar sync the user allows Memorri to use Calendar and Reminders (the system asks once for each), then picks the calendar that will hold appointments and the Reminders list that will hold tasks, deadlines and reminders. Nothing is written until both choices are made (or one, if the user only wants one kind) and sync is switched on. The tab says in plain words what each permission is for and what Memorri will and will not change.

**Why this priority**: nothing else works without the permissions and the two targets.

**Independent Test**: With no calendar chosen nothing is written; with neither permission, the tab shows what is missing and a button to ask; after allowing, the pickers list the calendars and lists the user can write to; the choice is remembered after a restart; if access is later revoked in System Settings, the tab says so and sync stops without error.

**Acceptance Scenarios**:
1. **Given** no permission, **When** the user presses `Allow Calendar` and accepts, **Then** the calendars that accept new events are offered, with their account names.
2. **Given** a calendar other than the chosen one holds events, **When** sync runs, **Then** those calendars are never read for writing, changed or deleted from.
3. **Given** both targets chosen, **When** the user switches sync on, **Then** the tab shows what would be synced now (counts) before anything is written.
4. **Given** access is revoked later, **When** the tab opens or sync tries to run, **Then** it shows `Access to Calendar was turned off` with a button that opens System Settings, and nothing is written.
5. **Given** the chosen calendar or list is deleted in Calendar or Reminders, **When** sync next runs, **Then** it stops and asks the user to choose another.

---

### User Story 2 - Items appear in Calendar and Reminders, and stay in step (Priority: P1)
Items that are ready (active, and not waiting in the Inbox) are written to the chosen targets: an appointment as a calendar event with its start, end (or all-day), place and people; a task or deadline as a reminder with its due date; a reminder with an alarm at its remind time. Each entry has a title with the context (`[Customer] Standup`), notes that say Memorri made it, list the evidence (capture time, where it was read) and carry a link that opens the item in Memorri. When an item changes in Memorri (edited, approved, a better reading, merged), the same entry is updated, never duplicated. Items in the Inbox are not written until approved. A dismissed or merged-away item has its entry removed, and restoring it writes it again.

**Why this priority**: it is the purpose of the whole app: the user's other devices see the items through iCloud.

**Independent Test**: With three ready items (an appointment, a task with a due date, a reminder with an alarm), turn sync on: one event and two reminders appear with the right dates, titles and notes; edit the appointment's end in Memorri: the same event changes; sync again: nothing is duplicated; an item still in the Inbox is not written; approve it: it appears.

**Acceptance Scenarios**:
1. **Given** an active appointment that does not need review, **When** it syncs, **Then** a calendar event exists with the item's start and end in the item's time zone, the place, the context in the title, and notes with a Memorri link and evidence lines.
2. **Given** a task with a due date, **When** it syncs, **Then** a reminder exists with that due date; a reminder item also has an alarm at its remind time.
3. **Given** an item in the Inbox, **When** sync runs, **Then** nothing is written for it; after approval it is written.
4. **Given** a synced item, **When** its fields change in Memorri, **Then** the same event or reminder is updated and the number of entries does not change.
5. **Given** two items are merged, **When** sync runs, **Then** only one entry remains for them.
6. **Given** an item with no date at all, **When** sync runs, **Then** it is not written as an event; a task without a date is written as an undated reminder.
7. **Given** the app is quit and started again, **When** sync runs, **Then** it recognises its earlier entries and creates no duplicates.

---

### User Story 3 - Edits made in Calendar or Reminders are respected (Priority: P2)
If the user changes a synced event or reminder in Calendar.app or Reminders (title, time, place, notes, completed, deleted), Memorri notices on the next sync. A changed field is taken into the item as the user's own value (the field is locked, as for any edit), so Memorri never overwrites it later. A reminder marked completed is shown on the item as `Completed in Reminders` and is left completed (the item's own status does not change); an entry deleted by the user is not recreated and the item shows as removed from the calendar.

**Why this priority**: without it, the user would fight Memorri over every edit made where they actually live.

**Independent Test**: Change a synced event's time in Calendar.app; sync: the item's start shows the new time with a lock and a note `changed in Calendar`; a later better reading from a capture does not change it. Complete a synced reminder: the item shows `Completed in Reminders`. Delete a synced event: it does not come back.

**Acceptance Scenarios**:
1. **Given** an event changed in Calendar, **When** sync runs, **Then** the changed fields become locked user values on the item, and the event is not rewritten with Memorri's older values.
2. **Given** a reminder completed in Reminders, **When** sync runs, **Then** the item shows `Completed in Reminders` and the reminder stays completed.
3. **Given** an event deleted in Calendar, **When** sync runs, **Then** it is not recreated and the item is marked as not synced, with a way to sync it again.
4. **Given** a change made in both places since the last sync, **When** sync runs, **Then** the Calendar value wins for the changed field and the change is shown in the item's history.

---

### User Story 4 - Preview before writing (dry run) and see what happened (Priority: P2)
A `Preview` shows exactly what a sync would do (entries to create, update, remove or leave) with the item and the fields that would change, and writes nothing. A `Sync now` button runs it for real. Every run is summarised (created, updated, removed, skipped, failed with reasons) and the last runs are listed. Each item shows whether it is synced, when, and any problem.

**Why this priority**: the first sync writes into the user's real calendar; seeing it first is the safety.

**Independent Test**: Press Preview with five items: the list shows five creations and the calendar has no new entries; press Sync now: five entries appear; Preview again: nothing to do.

**Acceptance Scenarios**:
1. **Given** items ready to sync, **When** the user previews, **Then** the preview lists what would be created, updated or removed, and Calendar and Reminders are unchanged.
2. **Given** a sync ran, **When** the user opens the tab, **Then** the last runs show their counts and the reason for every failure.
3. **Given** a failure (for example the calendar is read-only), **When** sync runs, **Then** the other items still sync and the failed one is reported and retried next time.

---

### Edge Cases

- Time zones: an event keeps the item's own time zone; an all-day item is all-day.
- An item changes between a preview and the sync: the sync uses the items as they are when it runs.
- The target is an iCloud calendar still downloading, or an account that is offline: the run fails softly and retries later.
- The user has two items that look alike and merges them later: the entry of the item merged away is removed and the other is updated.
- Large libraries: first sync of thousands of items is done in batches without blocking the app, and can be cancelled.
- Items older than the user's choice of range (for example more than 90 days past) are not written, with the range stated in the tab.
- A user who never grants access: the rest of the app works as before.
- Privacy: only the fields listed above leave Memorri, to the user's own calendar store on this Mac (and what iCloud does with it); nothing goes anywhere else, and capture pictures are never attached.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings > Calendar sync MUST let the user grant Calendar and Reminders access, show the state of each permission, and open System Settings when it was turned off.
- **FR-002**: The user MUST pick the target calendar (events) and the target Reminders list (tasks, deadlines and reminders) from those that accept writes; the choices MUST be remembered.
- **FR-003**: Sync MUST be one-way from Memorri, except for the edits described in FR-009 to FR-011, and MUST never delete or change an entry it did not create.
- **FR-004**: Only items that are active and do not need review (approved by the user or ready by the Inbox rules) MUST be written; items in the Inbox are not, until approved.
- **FR-005**: An appointment MUST become a calendar event with its start and end (or all-day) in the item's time zone, its place and people; a task or deadline a reminder with its due date; a reminder an alarm at its remind time.
- **FR-006**: Titles MUST carry the item's context when it has one; notes MUST say the entry is made by Memorri, list the evidence (capture time and where it was read) and hold a link that opens the item in Memorri.
- **FR-007**: Every written entry MUST be recorded in `sync_links` with its EventKit identifier and a hash of the last synced state, so a later sync updates the same entry, never duplicates it, also after a restart.
- **FR-008**: When an item changes, the same entry MUST be updated; when two items are merged only one entry MUST remain; an item without a date MUST NOT become an event.
- **FR-009**: A change made to a synced entry in Calendar or Reminders MUST be detected by comparing it with the last synced state and MUST be taken into the item as the user's own value (the field is locked, the change appears in the item's history).
- **FR-010**: A reminder completed in Reminders MUST be shown on the item as `Completed in Reminders` and MUST stay completed; Memorri MUST NOT reopen it.
- **FR-011**: An entry deleted by the user in Calendar or Reminders MUST NOT be recreated; the item MUST show as not synced with a way to sync it again.
- **FR-012**: Sync MUST run automatically soon after an item becomes ready or changes (changes are grouped, not written one by one) and when the app starts, while sync is switched on and access is allowed; `Sync now` MUST run it at once and `Preview` MUST never write. The first sync after switching on MUST wait for the user to see a preview and press `Sync now`.
- **FR-013**: When an item is dismissed or merged away, the entry Memorri made for it MUST be removed; restoring the item MUST write it again. Entries Memorri did not make MUST never be removed.
- **FR-014**: A preview MUST list what a sync would create, update, remove or leave, with the fields that would change, and MUST write nothing.
- **FR-015**: Every run MUST be summarised (created, updated, removed, skipped, failed with reasons) and kept in a short list; a failure on one item MUST NOT stop the others and the item MUST be retried next time.
- **FR-016**: Each item MUST show whether it is synced, when, and any problem.
- **FR-017**: A user who turns sync off MUST be able to keep or remove the entries Memorri made.
- **FR-019**: Memorri MUST write to Calendar only in the calendar the user chose in Settings, and to Reminders only in the list the user chose. With no calendar chosen it MUST write no event at all (and with no list chosen, no reminder). Every create, update and delete MUST be refused if the entry is not in the chosen calendar or list, whatever the cause (a stale identifier, an entry moved by the user, a calendar deleted and made again).
- **FR-020**: Changing the chosen calendar or list MUST show a preview of the move first (Memorri's entries are removed from the old one and written to the new one) and MUST NOT touch the old one until the user confirms; entries the user moved into another calendar MUST be left where they are and treated as removed by the user.
- **FR-018**: Nothing but the fields of FR-005 and FR-006 MUST be written, and only to the chosen Calendar and Reminders list; capture pictures MUST NOT be attached.

### Key Entities

- **Sync target**: the chosen calendar and Reminders list (identifiers), and the permission state.
- **Sync link**: item id, kind of entry, EventKit identifier, hash of the last synced state, when, and state (synced, removed by the user, failed with a reason).
- **Sync run**: when, whether a preview, counts of created, updated, removed, skipped and failed, and the reasons.
- **Entry change**: a difference between an entry and its last synced state, taken into the item as a user value.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a first sync, 100% of ready items appear exactly once in the right target, with the right dates, and 0 items from the Inbox are written.
- **SC-002**: Running sync again, also after a restart, creates 0 duplicates and changes 0 entries when nothing changed.
- **SC-003**: 100% of edits made in Calendar or Reminders to a synced entry are taken into the item as locked values and are never overwritten by a later sync or analysis.
- **SC-004**: A preview writes nothing: Calendar and Reminders hold exactly the same entries before and after (checked by counting).
- **SC-005**: Entries Memorri did not create are never changed or deleted (checked on a calendar holding other events), and 0 writes ever reach a calendar or list other than the chosen ones (checked with several calendars present and with the choice changed mid-way).
- **SC-006**: A sync of 1,000 items completes without blocking the app and in under 60 seconds on a local calendar.
- **SC-007**: A user sets up targets and sees their first items in Calendar in at most five actions from opening the tab.

## Assumptions

- "Confident" means the Inbox rules already in place: an item is ready when it is active and does not need review, or when the user approved it.
- The deep link uses a custom URL scheme (`memorri://item/<id>`) that opens the Items window on that item.
- Only a calendar and a list the user can write to are offered; the app never creates calendars or lists itself.
- Two-way sync is limited to the field edits, completion and deletion of FR-009 to FR-011; Memorri does not import events it did not create.
- Past entries older than 90 days are not written (stated in the tab).
- Cancellation detection (an event vanishing from a calendar screenshot) stays in spec 010.
- Out of scope: sharing, attendees, recurring events, attachments, and syncing to other services.
