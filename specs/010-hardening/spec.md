# Feature Specification: Hardening for daily use

**Feature Branch**: `010-hardening`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0020 (items), 0021 (evidence and review state), 0022 (windows and the reference clock), 0025 (trials), 0026 (sync planner and scoped event store)

**Input**: User description: "Hardening for daily use. (1) Cancellation detection: when a calendar view that was captured earlier showed an item and a later capture of the same calendar range no longer shows it, the item becomes possibly cancelled and goes to the Inbox for review, never removed silently; coverage is the context plus the date range a calendar view showed. (2) Notifications: a local notification when new items arrive and when some need review (for example "3 new items, 1 needs review"), grouped so a burst gives one notice, with a setting to turn it off. (3) Launch at login, a setting. (4) Backup and export: export the items (and optionally the library) to a file the user chooses, and restore from a backup, with nothing sent to any service. (5) Diagnostics: a diagnostics view or export of the app's own log and counts (queue, sync, storage) that never includes captured content or item text." (roadmap 010). Specs 003 to 009 and 011 already ship the queue, items, the Inbox, search, reprocessing and the Calendar and Reminders sync.

## Clarifications

### Session 2026-10-02

- Q: How many later captures of the same calendar dates must leave out a meeting before it is marked `Possibly cancelled`? → A: Two separate later captures (taken at different moments) that cover the meeting's day and time and do not show it; a capture showing it in between resets the count.
- Q: Are new-item notifications on or off by default? → A: On; macOS is asked for permission the first time there is something to announce.
- Q: Does a full backup include the capture pictures? → A: The user chooses: `Include capture pictures` is offered with both sizes shown, on by default; without them the backup keeps the database and cut-outs, and a restored library cannot re-read or reprocess those captures.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A meeting that disappeared from the calendar is flagged, not lost (Priority: P1)
The user captures their work calendar every day. When a calendar view that once showed an appointment is captured again for the same dates and the appointment is no longer there, Memorri does not know whether it was cancelled, moved or simply hidden. The item is marked `Possibly cancelled` and appears in the Inbox with that reason, with the evidence of both captures. The user decides: `Cancelled` (the item is dismissed, and its Calendar entry is removed by sync), or `Still happening` (the item is approved, and that later capture is not held against it again). Nothing is removed or dismissed by Memorri on its own.

**Why this priority**: a calendar full of meetings that no longer exist is worse than no calendar; it is the main way a captured item turns false over time.

**Independent Test**: Capture a week view showing three meetings, then twice a week view of the same dates and context showing two. After the first of those nothing changes; after the second the missing one appears in the Inbox as `Possibly cancelled` with both captures as evidence. Press `Cancelled`: it is dismissed. For another, press `Still happening`: it leaves the Inbox and a further capture without it does not flag it again unless it is shown once more and then missing again.

**Acceptance Scenarios**:
1. **Given** an item seen in a calendar view of context C covering dates D, **When** two later captures of a calendar view of C whose dates cover the item's day and time show no sighting of it, **Then** the item gets the review reason `Possibly cancelled` and is listed in the Inbox; after only one such capture nothing happens yet.
2. **Given** a later capture that does not cover the item's day (another week, another month) or is of another context, **When** it shows no sighting of the item, **Then** nothing happens to the item.
3. **Given** a later capture of a screen that is not a calendar view (mail, chat, a document), **When** it is analysed, **Then** it never counts as evidence of absence.
4. **Given** an item that is possibly cancelled, **When** a still later capture of the range shows it again, **Then** the flag is cleared by itself and the item is back where it was.
5. **Given** the user presses `Cancelled`, **When** the item is dismissed, **Then** it is tombstoned like any dismissed item, and sync removes the entry it made; undo restores both.
6. **Given** the user presses `Still happening`, **When** later captures omit the item again, **Then** it is not flagged until it has been seen again after that decision.
7. **Given** an item the user edited or approved, **When** it vanishes from a later view, **Then** it is flagged all the same (only flagged, never changed), and its locked values stay.
8. **Given** an item with a Calendar entry made by sync, **When** it becomes possibly cancelled, **Then** the entry is left as it is until the user decides.

---

### User Story 2 - A library the user can take away and bring back (Priority: P1)
In Settings the user can export their items to a file they choose (every item with its fields, the sightings that back it, status and the user's own edits), readable outside Memorri, and can make a full backup of the library (items, captures, text, settings that belong to the library) to a place they choose. Restoring a full backup replaces the current library after a confirmation that shows what will be lost, and keeps a safety copy of the library it replaces. Nothing is sent to any service; the files are written only where the user picks.

**Why this priority**: the library holds weeks of captures that cannot be taken again; a broken disk, a new Mac or a bad update must not lose them.

**Independent Test**: Export items to a file and open it elsewhere: every item is there with its title, dates and status. Make a full backup, add and dismiss a few items, restore: the library is as it was at the backup, and the library before the restore is kept as a safety copy. Restoring a file that is not a Memorri backup, or one from a newer version, is refused with a clear message and changes nothing.

**Acceptance Scenarios**:
1. **Given** a library with items, **When** the user chooses `Export items…`, **Then** a single file with all items (including dismissed ones, marked as such) is written where they chose, and it contains no capture pictures.
2. **Given** the user chooses `Back up library…`, **When** it finishes, **Then** the backup holds everything needed to restore (items, sightings, captures with their text and cut-outs, contexts, settings of the library, and the capture pictures unless the user turned `Include capture pictures` off), and both sizes were shown before it started.
3. **Given** a backup, **When** the user chooses `Restore…` and confirms, **Then** the restore is staged and finished when Memorri restarts (the app offers `Restore and restart`, and `Cancel restore` until then); after the restart the library is the backup's, the app shows the restored items, and the replaced library remains as a safety copy that Settings > Storage shows and can delete.
4. **Given** a file that is damaged, not from Memorri, or from a newer version, **When** the user tries to restore it, **Then** nothing changes and the reason is shown.
5. **Given** the backup is large, **When** it runs, **Then** it shows progress, can be cancelled with nothing left half written, and the app stays usable.
6. **Given** a restored library that has Calendar sync links, **When** the app next runs sync, **Then** sync shows what it would do and writes nothing until the user confirms (the links may no longer match what Calendar holds).

---

### User Story 3 - A quiet notice when something needs the user (Priority: P2)
When analysis adds new items, Memorri shows one local notification such as `3 new items, 1 needs review`. A burst of captures gives one notice, not one per item. Nothing is shown while the Items window is in front, when there is nothing new, or when notifications are turned off in Memorri's settings or in macOS. Clicking the notification opens the Items window on the Inbox (or on the new items when none need review).

**Why this priority**: the app works in the background; without a notice the Inbox is only looked at when the user remembers.

**Independent Test**: Capture three times in a minute with items found: after analysis one notification appears with the totals. Turn the setting off: none appears. Capture while the Items window is frontmost: none appears.

**Acceptance Scenarios**:
1. **Given** analysis finished and added items, **When** a quiet moment has passed (no further items for a short time), **Then** one notification states how many new items and how many need review.
2. **Given** items were added in several captures within that time, **When** the notice is shown, **Then** it counts all of them once.
3. **Given** the Items window is frontmost, **When** items arrive, **Then** no notification is shown.
4. **Given** notifications are off in Memorri's settings, **When** items arrive, **Then** nothing is shown and nothing is asked of macOS.
5. **Given** a notification is clicked, **When** the app opens, **Then** the Items window shows the Inbox (or the new items).
6. **Given** a library re-read or a reprocessing trial applied (spec 008), **When** items are replaced rather than found, **Then** no notification is shown for them.
7. **Given** items that were flagged `Possibly cancelled`, **When** the notice is shown, **Then** they count among those that need review.

---

### User Story 4 - Memorri starts with the Mac (Priority: P3)
A setting `Open Memorri at login` (off by default) starts the menu-bar app when the user logs in, so captures with the shortcut work without launching anything. The setting reflects the system's real state: if the user removes the login item in System Settings, the switch shows it as off.

**Why this priority**: small, but a menu-bar tool that is not running when needed is not used.

**Independent Test**: Switch it on, log out and in: Memorri is in the menu bar. Remove it in System Settings > Login Items: the switch in Memorri shows off.

**Acceptance Scenarios**:
1. **Given** the setting is off, **When** the user switches it on, **Then** Memorri is registered as a login item and the switch stays on after a restart.
2. **Given** the login item was removed in System Settings, **When** the settings open, **Then** the switch shows off.
3. **Given** macOS asks for approval of the login item, **When** it is pending, **Then** the setting says so and offers to open System Settings.

---

### User Story 5 - Diagnostics that never leak the library (Priority: P3)
Settings has a Diagnostics section showing what the app is doing and a button to save a report. The report holds versions, the state of the queue (counts of waiting, running, failed jobs and the reasons for failures), the state of sync (counts, last runs and problems), storage use, permission states, and the app's own recent log lines. It never contains item titles, places, people, notes, OCR text, model output or pictures, so it can be shared with whoever helps fix a problem.

**Why this priority**: when something stalls, the user needs something to look at and to send, without reading logs in a terminal and without exposing client material.

**Independent Test**: Open Diagnostics: counts match the menu and Settings. Save a report from a library full of known strings (titles, places, OCR text): none of those strings occurs in the file.

**Acceptance Scenarios**:
1. **Given** the app is running, **When** the user opens Diagnostics, **Then** the queue, sync and storage figures and the permission states are shown.
2. **Given** a failed job, **When** the report is saved, **Then** it includes the kind of job and the failure reason, and no capture content.
3. **Given** a library with distinctive titles, places and OCR text, **When** a report is saved, **Then** a search of the report for any of them finds nothing.
4. **Given** the report is saved, **When** the user looks at it, **Then** it is a plain file in a place they chose, and nothing is sent anywhere.

---

### User Story 6 - Memorri has an icon of its own (Priority: P3)
Memorri shows a simple app icon of its own, the same brain as the menu-bar icon on a plain rounded background, wherever macOS shows the app: Finder, Login Items, Settings lists, notifications and the About panel. Nothing fancy: one icon, light and dark appearances need not differ.

**Why this priority**: a generic placeholder icon makes a real tool look unfinished and makes it hard to find in lists like Login Items and Privacy settings.

**Independent Test**: Build the app and look at it in Finder, in System Settings > Privacy & Security > Screen Recording and in a notification: the brain icon shows at every size, sharp, and not the generic app icon.

**Acceptance Scenarios**:
1. **Given** the built app, **When** it is shown in Finder at small and large sizes, **Then** the icon is the brain on a rounded square, sharp at every size.
2. **Given** the permission lists in System Settings, **When** Memorri is listed, **Then** it shows the same icon.
3. **Given** a notification from Memorri, **When** it is shown, **Then** it carries the icon.

---

### Edge Cases

- Cancellation: a calendar view that is cut off (only part of the week visible), a day column hidden behind another window, a time range scrolled out of view: the item counts as covered only if its cell was in the visible part of the view.
- Cancellation: a meeting that moved to another time within the covered range appears as a new sighting; the old item is flagged, and the user can merge them with the usual tools.
- Cancellation: the same appointment shown in two calendar windows of the same context, one hiding it: it is flagged only if no covering view shows it.
- Cancellation: items made from one capture only (never seen twice) are checked against later captures like any other; an item with sightings from non-calendar screens only is never flagged.
- Cancellation: a view whose date range cannot be read records no coverage, so it can never flag anything.
- Cancellation: a capture with no context never records coverage and never flags anything, so unrelated sessions without a context cannot flag each other's meetings; the context used is the capture's context when it is checked, so changing a capture's context later changes what it can flag.
- Cancellation: only week and day views count; a month view cuts its cells off (`+3 more`), so it proves nothing about absence.
- Cancellation: when the retention policy or the user deletes the captures that backed a suspicion, the flag may disappear with them; that is accepted, the evidence is gone.
- Notifications: the user denied notifications in macOS; the settings say so and offer to open System Settings, and the rest of the app works.
- Notifications: first launch after an update that re-reads the library: no flood.
- Backup: not enough free space (checked before starting), a destination that disappears, the library changing while it is copied (the backup is consistent as of one moment).
- Restore: it is staged while the app runs and finished at the next start, before the library is opened, so nothing is writing to it; a staged restore can be cancelled until then, and an interrupted restore at start moves everything back.
- Diagnostics: the app's log lines are checked for content before they are included; lines that cannot be shown to hold none are dropped.
- Privacy: backups and exports hold the user's real material and are not encrypted by Memorri; the screens say so in plain words and where the file is.

## Requirements *(mandatory)*

### Functional Requirements

**Cancellation detection**
- **FR-001**: For every analysed capture of a week or day calendar view that has a context, Memorri MUST record what that view covered: the dates it showed and which part of those dates was visible (month views and captures without a context record nothing).
- **FR-002**: When two later captures (taken at different moments, after the last capture that showed the item) of a calendar view of the same context cover an item's day and time and hold no sighting of that item, Memorri MUST mark the item `Possibly cancelled` and put it in the Inbox with that reason. One such capture alone MUST NOT flag it; a capture that shows the item again resets the count.
- **FR-003**: Captures that are not week or day calendar views, captures without a context, views of another context, views whose dates do not cover the item, and views whose dates could not be read MUST NOT count as evidence of absence.
- **FR-004**: Memorri MUST NOT dismiss, delete, change or unsync an item or its Calendar entry because of a suspected cancellation; only the user's decision does.
- **FR-005**: `Cancelled` MUST dismiss the item exactly as `Dismiss` does (tombstone, sync removes the entry, undoable). `Still happening` MUST approve the item and MUST NOT flag it again until it has been seen in a later capture.
- **FR-006**: If a later covering view shows the item again, the flag MUST be removed automatically unless the user already decided.
- **FR-007**: The reason, the last capture that showed the item and the captures that covered it without it, MUST be visible in the item's detail.
- **FR-008**: Reprocessing trials, the library re-read and a reanalysis of the same capture MUST NOT create suspicions on their own; only new captures do.

**Notifications**
- **FR-009**: After analysis adds items, Memorri MUST show at most one local notification per quiet period, stating how many items are new and how many need review.
- **FR-010**: No notification MUST be shown when the Items window is frontmost, when nothing is new, when the setting is off, or when macOS notifications are not allowed; the setting MUST be on by default, and macOS permission MUST be asked only when the first notice is due (or when the user switches the setting on again), never at launch.
- **FR-011**: Clicking the notification MUST open the Items window on the Inbox, or on the new items when none need review.
- **FR-012**: Items that arrive through reprocessing apply, restore or library re-read MUST NOT be announced.
- **FR-013**: A setting in Settings MUST turn notifications on or off, and show the macOS permission state.

**Launch at login**
- **FR-014**: A setting `Open Memorri at login` MUST register and unregister the app as a login item and MUST show the system's actual state, including a pending approval.
- **FR-015**: The setting MUST be off by default.

**Backup and export**
- **FR-016**: The user MUST be able to export all items, with fields, status, user edits and the text of their sightings (no pictures), to one file they choose, in a form readable outside Memorri.
- **FR-017**: The user MUST be able to make a backup of the library (database, cut-outs and, when `Include capture pictures` is on, which it is by default, the capture pictures) to a location they choose, after being shown its size with and without pictures, with progress and cancel; a cancelled or failed backup MUST leave no partial file. A backup without pictures MUST say so when restored, and the restored captures MUST show as having no picture (they cannot be re-read or reprocessed).
- **FR-018**: A backup MUST be consistent as of one moment even while the app keeps working.
- **FR-019**: Restore MUST validate the file (is a Memorri backup, intact, not from a newer version), show what will be replaced (and that a backup has no capture pictures, when so), require confirmation, be finishable only at the next start and cancellable until then, keep the replaced library as a safety copy, and leave the current library untouched on any failure.
- **FR-020**: After a restore, sync MUST NOT write anything until the user has seen a preview and confirmed (links may be stale).
- **FR-021**: Safety copies MUST be listed in Settings > Storage with their size and a way to delete them.
- **FR-022**: Nothing in export, backup or restore MUST use the network; files go only where the user picks. The screens MUST say that files are not encrypted.

**Diagnostics**
- **FR-023**: Settings MUST show a Diagnostics section with app and system versions, permission states, queue counts and failure reasons, sync state and last problems, and storage use.
- **FR-024**: The user MUST be able to save a diagnostic report, a plain file in a place they choose, holding those figures and the app's recent log lines.
- **FR-025**: The report and the screen MUST NOT contain item titles, places, people, notes, OCR text, model output, window titles or pictures; log lines that cannot be shown to hold none MUST be left out.
- **FR-026**: Saving a report MUST send nothing anywhere.

**App icon**
- **FR-027**: The app MUST have an app icon showing the brain of the menu-bar icon on a plain rounded background, provided at every size macOS asks for, and used wherever the system shows the app.
- **FR-028**: The icon MUST be produced by a script kept in the repository, so it can be redrawn at any size without a design tool; the menu-bar icon stays as it is.

### Key Entities

- **Calendar coverage**: for one analysed week or day view: the stretches of time each visible day column showed (days hidden or cut off, and times scrolled out of view, are left out); its context is the capture's.
- **Cancellation suspicion**: an item's review reason `Possibly cancelled`, with the last capture that showed it and the (at least two) captures that covered it without it; cleared by reappearance or by the user's decision.
- **Notification setting and pending notice**: whether on, the counts waiting for the quiet period, when the last notice was shown.
- **Library backup**: one file or folder holding the library at a moment, with a version, whether it includes pictures, a manifest of what it holds and a check value.
- **Safety copy**: the library a restore replaced, kept until the user deletes it.
- **Diagnostic report**: a plain text or JSON file of figures, states and sanitised log lines.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a set of captured calendar sequences with known cancellations, at least 90% of the cancelled meetings are flagged in the Inbox, and no more than 1 in 20 flags is for a meeting that is in fact still there (measured on synthetic sequences).
- **SC-002**: 0 items are dismissed, deleted, changed or removed from Calendar by a suspected cancellation without the user's decision.
- **SC-003**: Captures that are not calendar views, or that do not cover an item's day, produce 0 flags (checked on mixed sequences).
- **SC-004**: A burst of 10 captures within one minute produces 1 notification, and 0 while the Items window is frontmost or the setting is off.
- **SC-005**: After export, 100% of items (including dismissed ones) are present in the file; after backup and restore, the library's items, sightings and settings are identical to those at the backup (checked by comparing counts and content).
- **SC-006**: A restore that fails for any reason, or is cancelled, leaves the current library exactly as it was (checked by comparison), and a successful restore keeps a safety copy of the replaced library.
- **SC-007**: A backup of a library of about 1 GB finishes in under 2 minutes on a local disk and the app stays responsive while it runs.
- **SC-008**: A diagnostic report made from a library holding known titles, places, people, notes and OCR text contains none of them (checked by searching the file), and takes at most 3 actions from opening Settings.
- **SC-009**: The login setting always matches what System Settings shows.
- **SC-010**: The built app shows its own icon, not the generic one, in Finder, in System Settings lists and in notifications, at every size, and the icon can be regenerated by running one command.

## Assumptions

- Coverage can only be recorded when the capture's analysis read the calendar window's dates from its headers; where it could not, no coverage is recorded and nothing is flagged (the detection errs toward silence).
- A calendar view that can prove absence is a week or day screen as the analysis already classifies them; the visible part of a window comes from the windows analysis of spec 011.
- `Possibly cancelled` is a new review reason of the existing Inbox; no new item status is added.
- Export format is one JSON file; the full backup is one package the app can read back; the exact container is a planning choice.
- Restore replaces the whole library; merging a backup into an existing library is out of scope.
- Notifications use the system's local notifications; no push, no network. The quiet period is a few seconds to a minute (planning decides).
- Cancelling an item flagged because an entry vanished from one view does not touch other contexts' items.
- The app icon is a simple drawing (the brain symbol on a rounded square in a single colour); a designed icon is out of scope.
- Out of scope: automatic scheduled backups, encryption of backups, cloud destinations, importing from other apps, notifications for sync problems, and crash reporting.
