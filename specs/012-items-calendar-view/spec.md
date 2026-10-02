# Feature Specification: See items on a calendar, with a one-row header

**Feature Branch**: `012-items-calendar-view`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0020 (items), 0021 (evidence and review state), 0023 (search)

**Input**: User description: "A calendar view for the Items window and a single-row header. Today the Items window shows a list on the left and the open item on the right; most items have a date, so add a month calendar view where each item is pinned in the cell of its day (an appointment on its start day, a task, deadline or reminder on its due day), with a way to switch between the list and the calendar, to move between months and back to today, and to open an item from a day cell into the same detail pane. The header is two rows of segmented controls today and should become one row: Items/Inbox/Approved becomes a dropdown filter, Approve and Dismiss (and Merge, Restore) become icon buttons (check, X) shown only when the selection allows them, Undo last becomes an icon-only button, and the search field, kind and context filters and the show-dismissed choice stay in the same row. Prefer an existing free open-source calendar component (or the system one) over a hand-built calendar to keep custom code small. Specs 005, 006 and 007 already ship items, the Items window with its Inbox and the search field."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One tidy header row (Priority: P1)
The Items window header is one row. From left to right: the view switch (List or Calendar), the kind filter, the context filter, a `Show` dropdown with Items, Inbox (with its count) and Approved, the show-dismissed choice, the search field, then icon buttons for the actions that apply to the selection (Approve as a check, Dismiss as an X, Restore, Merge) and an icon-only Undo. Actions appear only when the selection allows them.

**Why this priority**: it is the part the user sees all day, it is the smallest change, and it makes room for the calendar controls. It ships on its own.

**Independent Test**: Open the Items window; the header is one row at the default width and at the smallest width; selecting nothing shows no action icons; selecting an item that needs review shows Approve and Dismiss; selecting a dismissed item shows Restore; selecting two items shows Merge; Undo is dimmed until there is something to undo and says what it will undo when hovered.

**Acceptance Scenarios**:
1. **Given** no selection, **When** the window opens, **Then** the row holds the view switch, filters, Show dropdown, search field and the Undo icon, and no Approve, Dismiss, Restore or Merge icon.
2. **Given** items in the Inbox, **When** the user opens the Show dropdown, **Then** it lists Items, Inbox (N) and Approved with the current one checked, and choosing one changes the list as the segments did.
3. **Given** one item that needs review is selected, **When** the row updates, **Then** a check (Approve) and an X (Dismiss) icon appear, each with a tooltip and a spoken label, and activating them does what the buttons did.
4. **Given** the window is at its smallest width, **When** all controls are present, **Then** nothing wraps to a second row and nothing is cut off (secondary controls may collapse into a menu).
5. **Given** an operation was done, **When** the user hovers the Undo icon, **Then** it says `Undo: <what>`; with nothing to undo it is dimmed and says `Nothing to undo`.

---

### User Story 2 - See items on a month calendar (Priority: P1)
A switch in the header changes the left pane from the list to a month calendar. Each item is pinned in the cell of its day: an appointment on its start day, a task, deadline or reminder on its due day (or its start day when it has no due date). A cell shows the first few items as short chips with their times and a `+N more` when there are more; the month title, previous and next month buttons and a Today button are above the grid. Clicking an item chip selects it and shows it in the same detail pane on the right, with its evidence, fields and actions as in the list. Items with no date at all are listed under the grid as `No date` so none are lost.

**Why this priority**: it is the point of the request: most items have dates and are easier to understand in place on a month.

**Independent Test**: With items on different days of two months, switch to Calendar; each item is in the right cell; move to the next and previous month and back to today; choose an item chip; the detail pane shows it; switch back to the list and the same item is still selected.

**Acceptance Scenarios**:
1. **Given** an appointment on 13 October at 10:00 and a task due on 13 October, **When** the calendar shows October, **Then** both are in the 13 cell, appointment first by time.
2. **Given** a day with seven items, **When** the cell is shown, **Then** it shows the first few, ordered by time, and `+4 more`; choosing `+4 more` (or the day number) lists that day's items so any can be opened.
3. **Given** the calendar, **When** the user presses Next, Previous or Today, **Then** the grid moves a month or returns to the month of today, with today's cell marked.
4. **Given** an item is selected in the list, **When** the user switches to Calendar, **Then** the calendar shows the item's month with the item selected, and the detail pane stays open.
5. **Given** items without start or due date, **When** the calendar is shown, **Then** they appear under the grid as `No date` and can be opened.
6. **Given** an all-day item, **When** pinned, **Then** it shows without a time and sorts before timed items of that day.

---

### User Story 3 - The calendar follows the filters and stays in step (Priority: P2)
Everything that narrows the list narrows the calendar: kind, context, the Show dropdown (Items, Inbox, Approved), show dismissed and the search field. Approving, dismissing, restoring, merging, editing a date and undoing change the calendar at once. Dismissed items, when shown, look dimmed; items that need review are marked. The chosen view (List or Calendar) and the month being looked at are remembered the next time the window opens.

**Why this priority**: a calendar that ignored the filters would contradict the list; staying in step makes it trustworthy. Builds on stories 1 and 2.

**Independent Test**: With the calendar open, choose Tasks, a context, Inbox and a search word in turn; the pinned items match exactly what the list shows for the same controls. Edit an item's start to another day: it moves cells. Merge two items: one chip remains. Quit and reopen: the same view and month.

**Acceptance Scenarios**:
1. **Given** filters are set, **When** the user switches between List and Calendar, **Then** the set of items is the same in both.
2. **Given** an item is pinned on 13 October, **When** its start is edited to 20 October, **Then** its chip moves to the 20 cell without reloading.
3. **Given** two items on the same day are merged, **When** the calendar updates, **Then** one chip remains and it is selected.
4. **Given** the user left the window on the calendar in March, **When** the window is opened again, **Then** it shows the calendar in March.
5. **Given** an item needs review, **When** it is pinned, **Then** its chip shows a review mark and a spoken `needs review`.

---

### Edge Cases

- A month with no items shows an empty grid and the message `Nothing on this month`, still with the controls to move on.
- An item that spans days (an appointment from 22:00 to 02:00) is pinned on its start day only, with its start time.
- Times are shown in the item's own time zone, and the day is its day in that zone, as in the list.
- The first weekday follows the system setting.
- Very long titles are cut with an ellipsis in a cell and shown whole in the tooltip and detail.
- A narrow window shows fewer chips per cell; the grid never scrolls sideways.
- Dismissed items are hidden unless shown; merged items never appear on their own.
- Keyboard: arrow keys move between days, Return opens the first item of the day, and Command-arrow keys move between months; the whole calendar and header are usable with VoiceOver.
- Switching view or month never changes the selection or discards an open edit in the detail pane.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Items window header MUST be a single row at every supported window width, holding the view switch, kind filter, context filter, the Show dropdown, the show-dismissed choice, the search field, the action icons and the Undo icon.
- **FR-002**: Items, Inbox (with its count) and Approved MUST be chosen from one dropdown that shows the current choice, replacing the three segments, with the same meaning as before.
- **FR-003**: Approve, Dismiss, Restore and Merge MUST be icon buttons shown only while the selection allows them (the same rules as today), each with a tooltip and a spoken label.
- **FR-004**: Undo MUST be an icon-only button, dimmed when there is nothing to undo, with a tooltip naming the operation it would undo.
- **FR-005**: A control in the header MUST switch the left pane between the list and a month calendar; the detail pane stays on the right in both.
- **FR-006**: The calendar MUST pin each item in the cell of its day: appointments by start; tasks, deadlines and reminders by due date, else start; the day is read in the item's time zone.
- **FR-007**: A cell MUST show up to a few items as chips (title, time, kind mark, review and dismissed marks), ordered all-day first then by time, and `+N more` when there are more, which lists the day's items.
- **FR-008**: The calendar MUST have previous month, next month and Today controls, a month title and a mark on today.
- **FR-009**: Choosing an item in the calendar MUST select it and show it in the detail pane exactly as selecting it in the list does, including multi-selection for merge where the list allows it.
- **FR-010**: Items without a start or due date MUST be listed under the calendar as `No date` and be selectable.
- **FR-011**: Kind, context, Show, show-dismissed and the search field MUST apply to the calendar with the same results as the list; the same rules decide what is visible.
- **FR-012**: The calendar MUST update at once after approve, dismiss, restore, merge, split, undo, edits and new analyses, without reloading the window.
- **FR-013**: Switching between list and calendar MUST keep the selection and the open detail.
- **FR-014**: The window MUST remember the view (list or calendar) and the month shown between launches.
- **FR-015**: The calendar and header MUST work with the keyboard alone and with VoiceOver, with a spoken label for every chip (`<kind>, <title>, <time>, needs review`), every day cell (`13 October, 3 items`) and every icon.
- **FR-016**: The calendar MUST use an existing component (the system's or a maintained open-source one) for the month grid and navigation where one fits, keeping hand-written code to the pinning, chips and wiring; the choice and its alternatives are recorded in the plan.

### Key Entities

- **Item day**: the day an item is pinned to (start day, due day, or none) in its own time zone.
- **Day cell**: a date with its pinned items in display order and the count not shown.
- **View mode**: list or calendar, with the month in view; remembered between launches.
- **Header controls**: the one-row set of filters, view switch, search and actions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At the smallest window width and the default one, the header is one row with nothing cut off (checked in the running app at both widths).
- **SC-002**: 100% of the dated items the list shows for a given set of filters appear in exactly one cell of the calendar, and the undated ones under `No date` (checked on a test library for every combination of kind, context, Show and dismissed).
- **SC-003**: Switching list/calendar and moving between months takes under 200 ms on a library of 5,000 items.
- **SC-004**: A user finds the items of a given day and opens one in at most two actions from the list view (switch to Calendar, choose the chip).
- **SC-005**: After each of approve, dismiss, restore, merge, split, undo and a date edit, the calendar shows the new state with no stale or missing chip (checked by tests on every operation).
- **SC-006**: The header controls that existed before (filters, Show, search, approve, dismiss, merge, restore, undo) all remain reachable and do what they did (no regression in the existing item tests).
- **SC-007**: The month grid is not hand-written: the custom calendar code is limited to pinning, chips and wiring (reviewed in the PR).

## Assumptions

- This spec is built on top of spec 007's branch (it moves the Items window's search field) and on the Items window of spec 006.
- The kind filter (All, Appointments, Tasks, Reminders) stays a segmented control; context stays a dropdown; if the row does not fit at the smallest width, the kind filter collapses into a dropdown.
- The calendar shows one month at a time (week and day views are out of scope), Monday or Sunday first as the system says.
- Dragging an item to another day to change its date is out of scope (dates change through the detail pane's editing).
- Items with a reminder time but no due date are pinned by their start, else listed as `No date`; the remind time is not a pinning date.
- Items from the calendar view and the list share one selection and one detail pane; there is no separate calendar detail.
- No new data is stored except the remembered view and month (a preference).
- Subscribing to an external calendar, showing Apple Calendar events and sync (spec 009) are out of scope.
