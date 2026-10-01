# Feature Specification: Read each window on its own, so dates come from the window that shows them

**Feature Branch**: `011-window-aware-analysis`

**Created**: 2026-10-01

**Status**: Draft

**Related ADRs**: 0014 (analysis jobs), 0018 (month grids are read from their geometry), 0020 (reconciliation), 0021 (evidence and review state)

**Related**: `docs/postmortems/2026-10-01-month-view-read-as-the-capture-month.md`

**Input**: User description: "Window-aware analysis. A real desktop shows several windows at once (a calendar, mail, chat, a browser, a terminal) and a capture today gets one classification and one extraction for the whole picture, with the calendar found afterwards by looking at the text. Make the analysis work window by window: split each capture into the windows that are actually visible (using the stored window stack, so a window in front hides the text of those behind it); decide for each visible window whether it holds events, tasks or reminders and of which kind (calendar month, week or day, mail, chat, document); extract each such window on its own; take the date context (month, year, time zone, header and title texts, labels) only from that window; read the clock in the menu bar as the capture's reference date when it is there; never be silently sure of a month or year that nothing on the screen names (such a date is flagged as a guess and goes to the Inbox); and keep one list of items across windows and captures with no duplicates."

## Why this exists

On 1 October 2026 a calendar left on February 2026 was analysed and every entry came out in October and November. The picture said February in two places; the code never looked at the right words, and nothing marked the date as a guess. A stop-gap already ships: the month title and a month label are read, the calendar's own window is used for the date context, and a month nobody names is flagged as a guess. That fixes the one failure. It does not change the way a picture is analysed: one classification and one extraction for the whole screen, the calendar found afterwards by its text. The same weakness will show again with two calendars on screen, a mail window beside a calendar, a remote desktop with its own clock, or a window half-covered by another. This spec makes the window the unit of analysis.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Two windows on screen, two correct readings (Priority: P1)

The user works with a calendar and a mail window side by side, a browser behind them and a terminal behind that. They press the capture shortcut. They expect the appointments of the calendar and the request in the mail to become items, each with the date its own window gives, and nothing from the browser or the terminal.

**Why this priority**: This is how the screens that matter look. Reading the whole picture as one thing is where wrong dates and invented items come from: numbers and month names of one window land in the reading of another.

**Independent Test**: Analyse a synthetic capture with a calendar, a mail window and a text-heavy window behind them, and check every item against the window it belongs to, and that nothing was taken from the covered or irrelevant text.

**Acceptance Scenarios**:

1. **Given** a capture with a month calendar and a mail window that mentions a date, **When** it is analysed, **Then** the calendar's entries get the month and year their own window names, and the mail's request gets the date its own text and headers give; neither window's text is used for the other's dates.
2. **Given** a window partly covered by a window in front, **When** it is analysed, **Then** only the text that can be seen is used, and nothing is read from the covered part.
3. **Given** a window that cannot hold events (a terminal, a code editor, a file list), **When** the capture is analysed, **Then** it produces no items and does not cost a model call.
4. **Given** two calendar windows on one screen (two accounts or two views), **When** the capture is analysed, **Then** each is read on its own and an event shown in both becomes one item with two sightings, not two items.

---

### User Story 2 - A calendar on another month is read in that month, or flagged (Priority: P1)

The user leaves a calendar on February while it is October, or looks at next week's view. The entries must carry the dates the window shows. When the window itself does not say which month or year it is, the dates are marked as guesses and the item goes to the Inbox.

**Why this priority**: A confident wrong date is worse than a flagged one: it looks right in the Items window and would be synced to the user's calendar.

**Independent Test**: Analyse synthetic month, week and day views on months other than the capture's, with and without a title, and check the dates and the guess flags.

**Acceptance Scenarios**:

1. **Given** a month view titled with February while the capture was taken in October, **When** it is analysed, **Then** every entry is dated in the months the window shows and none is flagged as a guess.
2. **Given** a week or day view whose only month evidence is a title in another month than the capture's, **When** it is analysed, **Then** the days are read in the title's month.
3. **Given** a view where nothing names the month or year, **When** it is analysed, **Then** the dates use the capture's date, are marked as guessed, and the items appear in the Inbox with the reason "Guessed time".
4. **Given** evidence in the same window that disagrees (a title says one month, the labels of the grid say another), **When** the window is analysed, **Then** the dates are flagged as guesses instead of choosing silently.

---

### User Story 3 - The date a window thinks it is (Priority: P2)

A mail says "tomorrow" or "Friday". The user's desktop clock, or the clock of a remote desktop shown in a window, tells which day that message was read, in which time zone. The analysis uses the clock the window itself sits in, then the screen's clock, then the capture's time.

**Why this priority**: Remote sessions often run in another time zone and on their own clock, which is exactly the case the app exists for. The gain is real but smaller than the two stories above.

**Independent Test**: Analyse a synthetic capture of a remote-desktop window whose taskbar clock differs from the Mac's, with a mail saying "tomorrow", and check the resolved date and time zone.

**Acceptance Scenarios**:

1. **Given** a capture whose screen shows a clock with a date, **When** relative dates ("today", "tomorrow", a weekday) are resolved, **Then** they are resolved from that clock, and the capture's own time is used only when no clock is readable.
2. **Given** a remote-desktop window with its own clock and date, **When** a window inside it is analysed, **Then** the remote clock is the reference for that window and the Mac's clock is not.
3. **Given** a clock that cannot be read or disagrees with the capture time by more than a day, **When** dates are resolved, **Then** the capture time is used and the dates that depend on it are marked as guesses.

---

### User Story 4 - See which window an item came from (Priority: P3)

The user opens an item and sees, with each sighting, the window it was read from: the application and window title, shown next to the cut-out. They can tell a sighting from "Calendar" from one from "Mail".

**Why this priority**: It is the visible trace of the change and helps checking an item, but nothing depends on it.

**Independent Test**: Analyse a capture with two windows and check that each sighting names its window in the item detail.

**Acceptance Scenarios**:

1. **Given** items from two windows of one capture, **When** the user opens each, **Then** its sighting names the application and window title it was read from.
2. **Given** a capture made before windows were recorded, **When** the user opens an item from it, **Then** the sighting simply shows no window name.

---

### User Story 5 - Older captures and cost stay under control (Priority: P2)

Captures made before the window stack was recorded, and captures of a single full-screen window, are analysed as one window and give the same results as today. The number of model calls per capture does not grow with the number of windows on screen.

**Why this priority**: The analysis runs on a local model that takes tens of seconds per call, in the background, on every capture. Cost and the existing library both limit the design.

**Independent Test**: Re-analyse the stored captures that have no window stack and the existing synthetic set; compare findings and the number of model calls before and after.

**Acceptance Scenarios**:

1. **Given** a stored capture with no window stack, **When** it is analysed again, **Then** it is treated as one window and its findings equal those of the analysis before this feature.
2. **Given** a screen with six windows of which one holds a calendar, **When** it is analysed, **Then** the number of model calls is no more than one plus the number of windows that can hold events, and a month grid needs none.
3. **Given** a capture already analysed whose windows have not changed, **When** it is analysed again, **Then** what is stored (text, kinds) is reused and no model call is repeated.

### Edge Cases

- A window fills the whole screen: it is the only window and the screen's menu bar and dock are not part of it.
- A window is mostly covered by one in front: only its visible part is read, and if too little is visible to read a title or a day, its dates are flagged as guesses.
- A dialog or menu is drawn over a calendar: its text never becomes an entry of the calendar.
- Two windows of the same application (two calendar windows, two mail messages) show the same event: one item, two sightings.
- A remote-desktop window contains a whole desktop with its own windows: the inner windows are not in the stack, so the remote window is read as one window with its own clock.
- Windows move between the capture and the analysis: the stored stack and frames of the capture are used, never the live desktop.
- A capture with several displays: each display's picture is analysed on its own with its own windows, as today.
- A window changes kind between captures (a calendar replaced by a mail in the same place): each capture is read on its own, and the items follow reconciliation as before.
- The window holds a month title and a different month in labels (see Story 2, scenario 4): flagged, never silently chosen.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST split each capture into its visible windows from the stored window stack and frames, and MUST treat the text of a window as hidden wherever a window in front covers it.
- **FR-002**: The system MUST decide for each visible window whether it can hold events, tasks or reminders and, if so, which kind of view it is (calendar month, week or day, mail, chat, document), and MUST NOT analyse windows that cannot hold any.
- **FR-003**: The system MUST extract each relevant window on its own, so that text of one window is never used to read the dates or entries of another.
- **FR-004**: The system MUST take the context for reading dates (month, year, header and title texts, labels, the time zone of the window's own surroundings) only from the window being read.
- **FR-005**: The system MUST use the clock it can read in the window's own surroundings (a remote desktop's clock), else the screen's clock, else the capture's time, as the reference for relative dates, and MUST mark dates that depend on a clock it could not read as guesses.
- **FR-006**: A date whose month or year is named by nothing in its window MUST be marked as a guess, and an item with a guessed date MUST appear in the Inbox with the reason "Guessed time".
- **FR-007**: When two pieces of evidence in one window disagree about the month or year, the system MUST mark the dates as guesses and MUST NOT choose silently.
- **FR-008**: The system MUST keep one list of items across windows and captures: an event shown in two windows or in two captures is one item with several sightings (reconciliation of spec 005 applies unchanged).
- **FR-009**: Each sighting MUST record the window it was read from (application and title) when the capture has windows recorded, and the item detail MUST show it.
- **FR-010**: A capture with no window stack MUST be analysed as one window and MUST give the same findings as the analysis before this feature.
- **FR-011**: The number of model calls for one capture MUST NOT exceed one plus the number of windows that can hold events, month grids read from their geometry MUST NOT need a model call, and results already stored (text, classification) MUST be reused.
- **FR-012**: The evaluation set MUST include captures with several windows, overlapping windows, a hidden window with misleading text, a remote window with its own clock, and calendar views on months other than the capture's, and the scores MUST be reported per case.
- **FR-013**: Evidence cut-outs and the "show whole capture" view (spec 006) MUST keep working for sightings from any window, with the cut-out inside the window it was read from.
- **FR-014**: Everything stays on the Mac: window frames, titles and clocks are read from the capture's stored data and the local model only.

### Key Entities

- **Visible window**: A window of a capture with the part of it that no window in front covers, its application name, title and the text read inside that part.
- **Window reading**: The result of reading one visible window: its kind of view, the date context taken from it, and the findings extracted from it.
- **Reference clock**: The date and time a window's relative dates are read against, with where it was found (the window's own surroundings, the screen, or the capture's time).
- **Sighting (extended)**: As in spec 005, plus the application and title of the window it was read from.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the synthetic set, every entry of a calendar view on a month other than the capture's gets a date in the month its window shows (100%, zero silent mismatches).
- **SC-002**: On synthetic captures with a window hidden behind or beside the calendar, zero entries or dates come from text of another window.
- **SC-003**: 100% of dates whose month or year nothing in their window names are marked as guesses and appear in the Inbox.
- **SC-004**: A capture with up to six windows needs no more model calls than one plus the number of windows that can hold events, and a month view needs none; the average time per capture on the existing synthetic set rises by no more than 25%.
- **SC-005**: Precision and recall on the existing synthetic cases do not fall (no case loses more than 0.02 on either), and captures without a window stack give identical findings.
- **SC-006**: On synthetic remote-desktop captures with their own clock, 100% of relative dates are resolved against that clock.
- **SC-007**: For items from captures with windows recorded, 100% of sightings name their window in the item detail.
- **SC-008**: Of the real captures stored on the developer's Mac that show a calendar on a month other than the capture's, every one is read in the month it shows, or is flagged, after re-reading from the stored text (checked by counts only; nothing from them is recorded).

## Assumptions

- The window stack and frames of each capture are stored with it (spec 002) and are good enough to tell which window is in front at a point; captures without the stack are read as one window.
- The stop-gap of spec 006's branch (month title and label reading, guess flag, window-scoped date context) is the starting point and its tests stay.
- Month grids keep being read from their geometry without a model call (ADR 0018); week, day, mail and chat views still need the model.
- The clock in the menu bar is read from the text of the picture like any other text; no extra permission is needed.
- Which windows can hold events is decided from the application, the window title and the text read, with the classification kept as the fallback for windows nothing else decides.
- Remote-desktop sessions are one window of the local desktop; windows inside them are not in the stack and are read as part of that window.
- The Items window shows the window name beside each sighting; a richer window browser is not part of this spec.
- Re-analysing the stored captures in a library is a separate step (spec 008, reprocessing), apart from one-off re-reads the user asks for.
