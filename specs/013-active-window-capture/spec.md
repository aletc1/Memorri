# Feature Specification: Capture only the active window, with its own shortcut and a red outline of what was recorded

**Feature Branch**: `013-active-window-capture`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0008 (configurable global shortcut, menu fallback), 0009 (capture storage), 0016 (window names stay local), 0021 (evidence and review state), 0022 (window-aware analysis)

**Related specs**: 001 (shortcut and menu), 002 (capture and storage), 011 (window-aware analysis)

**Input**: User description: "I want to capture just the active window with a new keybinding, and when capturing the window border goes red (something visually that shows the bounds and what was recorded). Current functionality and keybinding for the full screen record must remain working as is as today. This a new window capture functionality, and memorri needs to analyze that specific window instead of the full screen of all displays"

## Clarifications

### Session 2026-10-02

- Q: Where does a window capture wait in the analysis queue? → A: Same place as any new capture: after captures already waiting, ahead of the background re-read.
- Q: When the frontmost app has a small floating panel in front, which window is "the active window"? → A: The window that has keyboard focus (a panel or dialog when it is focused, otherwise the app's main window).

## Why this exists

Today every capture takes every display. That suits a quick "remember what is on my screens", but the user often knows exactly which window matters: one mail, one calendar, one remote session. Capturing everything around it costs analysis time on windows the user did not care about, can bring in items from other windows, and leaves the user unsure what Memorri actually took. A second shortcut that takes only the window in front, and outlines in red the area it recorded, gives a narrow capture whose scope the user can see. The full-screen capture stays exactly as it is.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Capture the window I am looking at (Priority: P1)

The user has a mail open in front, with a calendar, a browser and a chat behind it and on another display. They press the window-capture shortcut. Only the mail window is captured and analysed. The request in the mail becomes an item, and nothing from the calendar, the browser, the chat or the other display does.

**Why this priority**: This is the feature. Without it nothing else in this spec has a purpose.

**Independent Test**: With several windows open on two displays, press the window-capture shortcut on one window that holds a request, then check that the stored capture has one picture of only that window and that the only items created come from it.

**Acceptance Scenarios**:

1. **Given** several windows on one or more displays, **When** the user presses the window-capture shortcut, **Then** exactly one picture is stored, it shows only the window that has focus in the frontmost application, and no picture of any display is taken.
2. **Given** a window capture of a mail that asks for something by a date, **When** it is analysed, **Then** the item is created from that window, and no text outside the window is read.
3. **Given** a window capture, **When** it is analysed, **Then** it goes through the same later steps as any other capture: text reading, extraction, reconciliation with existing items, evidence cut-outs, the Inbox rules, search and reprocessing.
4. **Given** an event already known from an earlier full-screen capture, **When** a window capture shows the same event, **Then** it becomes a new sighting of the existing item, not a second item.
5. **Given** a remote-desktop client in front, full screen or not, **When** the user presses the window-capture shortcut, **Then** the client's whole window is captured and read as one window, as spec 011 reads remote sessions.

---

### User Story 2 - See exactly what was recorded (Priority: P1)

When the window capture fires, a red border appears around the window for a moment, showing the bounds of the picture that was taken. The user can tell at a glance that it was the right window and that nothing else was taken. The border never shows in the picture.

**Why this priority**: The user asked for it as part of the feature. A narrow capture that the user cannot see is easy to aim at the wrong window and hard to trust.

**Independent Test**: Trigger a window capture on windows of different sizes and positions and check that the red border matches the outline of the stored picture, that it disappears by itself, and that the stored picture has no red border in it.

**Acceptance Scenarios**:

1. **Given** a successful window capture, **When** the picture has been taken, **Then** a red border is drawn along the outline of the recorded area and disappears by itself after about one second.
2. **Given** the red border is showing, **When** the user types or clicks, **Then** the keys and clicks reach the windows below as usual; the border takes no focus and cannot be clicked.
3. **Given** a window capture, **When** the stored picture is opened, **Then** the border is not in it.
4. **Given** a window in full-screen mode or on its own Space, **When** it is captured, **Then** the border is shown over it on the display it is on.
5. **Given** a window capture fails or is refused, **When** the failure is reported, **Then** no red border is shown; the existing warning look and sound are used instead.
6. **Given** a successful window capture, **When** it completes, **Then** the usual confirmation (icon flash and sound, as set in Settings) also plays, so the shortcut feels like the capture the user already knows.

---

### User Story 3 - The full-screen capture is unchanged (Priority: P1)

The user keeps pressing Control+Option+Command+M or choosing "Capture now" and gets what they always got: one picture of every display, the same confirmation, the same analysis.

**Why this priority**: The user said so explicitly. A regression here would break the main way the app is used.

**Independent Test**: Run the existing capture tests and the evaluation harness on the existing golden set before and after the feature, and press the existing shortcut with several displays connected.

**Acceptance Scenarios**:

1. **Given** the feature is installed, **When** the user presses the existing capture shortcut or chooses "Capture now", **Then** every display is captured, with the same confirmation and no red border, exactly as before.
2. **Given** a customised capture shortcut, **When** the feature is installed, **Then** the customised shortcut is kept and still captures every display.
3. **Given** the existing golden set, **When** it is scored, **Then** the full-screen results are the same as before the feature.

---

### User Story 4 - Choose the window-capture shortcut, or use the menu (Priority: P2)

The window capture has its own shortcut with a default the user can change in Settings, next to the capture and search shortcuts. The menu-bar menu also offers "Capture window" as a fallback, as it does for "Capture now".

**Why this priority**: A default that works is enough to use the feature. Changing it matters when a remote-desktop client or another app uses the same keys.

**Independent Test**: Change the window-capture shortcut in Settings, try to set it to the capture or search shortcut or to one macOS owns, and use the menu item with a window in front.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** the user presses Control+Option+Command+W, **Then** the active window is captured.
2. **Given** Settings is open, **When** the user records a new window-capture shortcut, **Then** it replaces the default and survives a restart.
3. **Given** the user records a window-capture shortcut that equals the capture or search shortcut, or one macOS reserves, **When** it is recorded, **Then** it is refused with a message naming the conflict, and the previous shortcut stays.
4. **Given** a window in front of another application, **When** the user chooses "Capture window" in the Memorri menu, **Then** that window is captured, the same as with the shortcut.
5. **Given** a remote-desktop client in front and full screen, **When** the user presses the window-capture shortcut, **Then** it works as it does for the capture shortcut (spec 001); if the client swallows the keys, the user can choose another combination.

---

### User Story 5 - Tell window captures apart (Priority: P3)

In the menu's last-capture line and in the item detail, a window capture is shown as the window it took (application and title) rather than as a list of displays.

**Why this priority**: Helpful when checking where an item came from, but nothing depends on it.

**Independent Test**: Make one window capture and one full-screen capture, then check the last-capture line and the sightings of their items.

**Acceptance Scenarios**:

1. **Given** a window capture has just been taken, **When** the user opens the menu, **Then** the last-capture line says it was a window capture and names the application.
2. **Given** an item seen in a window capture, **When** the user opens it, **Then** its sighting names the application and window title of the captured window.

### Edge Cases

- **No window is active** (the desktop is focused, or the frontmost application has no open window): nothing is stored, the warning look and sound play, and the menu says there was no window to capture.
- **One of Memorri's own windows is in front** (Settings, Items, Inbox, search): it is never captured. Nothing is stored and the warning says Memorri's own windows are not captured.
- **A sheet or dialog is attached to the window in front**: the window is captured as macOS draws it at that moment, including what the system draws as part of it.
- **Another window or panel floats over part of the window**: the picture includes it (FR-008). The analysis treats the pictured area as one window; text of the covering window inside it may be read, and the dates of a finding are flagged as guesses where the covered area leaves too little visible to read a title or a day (spec 011).
- **The window in front is partly off the screen**: only the part on the screens is recorded, and the red border outlines that part.
- **The window spans two displays**: one picture of the whole window is stored, and the border is drawn on each display along the part it shows.
- **The window closes, minimises or moves in the moment of the capture**: if no picture could be taken, the capture fails with the warning; if a picture was taken, it is stored and the border shows where it was taken.
- **The shortcut is pressed twice quickly, or while another capture is running**: the same rule as the full-screen capture applies; a double press counts once, and a request while a capture runs is ignored. Window and full-screen captures share this rule.
- **Screen Recording permission is missing or revoked**: the same path as today: the tracked status changes and onboarding opens.
- **A window that cannot hold events** (a terminal, a code editor): it is captured, stored and read (FR-015); it simply gives no items.
- **Very small windows** (a tooltip-sized panel): captured like any other; the analysis may find nothing.
- **A full-screen remote session in front**: the client window covers the display, so the picture looks like a display capture, but it is stored and analysed as one window.

## Requirements *(mandatory)*

### Functional Requirements

**Trigger**

- **FR-001**: The system MUST offer a second global shortcut, "Capture window", separate from the existing capture shortcut, with the default Control+Option+Command+W.
- **FR-002**: The user MUST be able to change the window-capture shortcut in Settings, next to the capture and search shortcuts; the choice MUST survive restarts.
- **FR-003**: The system MUST refuse a window-capture shortcut that equals the capture or search shortcut or one macOS reserves, and MUST keep the previous one; the capture and search shortcuts MUST likewise refuse the window-capture shortcut.
- **FR-004**: The menu-bar menu MUST offer "Capture window" next to "Capture now", doing the same as the shortcut.

**What is captured**

- **FR-005**: The window capture MUST take exactly one picture: the window that has keyboard focus in the frontmost application at the moment of the request (a panel or dialog when it is the focused one, otherwise the application's main window), at its native pixel size, without the pointer.
- **FR-006**: The window capture MUST NOT take pictures of any display and MUST NOT store anything outside the captured window.
- **FR-007**: The window capture MUST NOT capture Memorri's own windows, the menu bar, the Dock or other system overlays; when no other window qualifies, it MUST store nothing and report "no window to capture" with the warning look and sound.
- **FR-008**: The picture MUST show what was on the screen inside the window's outline at that moment, including anything drawn over the window (another window, a floating panel, a menu); content of the window that was covered MUST NOT be recovered. The red border outlines the same area.
- **FR-009**: The stored capture MUST record that it is a window capture, what triggered it (shortcut or menu), the application name and window title, and the window's position on the desktop, under the same storage and privacy rules as captures of displays (stored locally only, never logged, removed with the capture and by "Delete everything"; ADR 0016).

**The red border**

- **FR-010**: After a successful window capture, the system MUST show a red border that follows the outline of the recorded area, on each display the area touches, including over full-screen windows and Spaces, and MUST remove it by itself after about one second.
- **FR-011**: The red border MUST NOT appear in the stored picture, MUST NOT take focus, and MUST let keys and clicks pass through to the windows below.
- **FR-012**: The red border MUST NOT be shown when the capture fails or is refused; the existing warning look and sound MUST be used instead.
- **FR-013**: A successful window capture MUST also play the usual capture confirmation (icon flash and sound, as set in Settings).

**Analysis**

- **FR-014**: A window capture MUST be analysed as one window: the whole picture is that window, no text outside its outline is used, and no other display or window is read for it.
- **FR-015**: The captured window MUST always be read for events, tasks and reminders because the user chose it; the window-sorting step of spec 011 MUST NOT mark it as not relevant, and only decides its kind of view (calendar month, week or day, mail, chat, document). A window that holds nothing gives no items.
- **FR-016**: Relative dates in a window capture MUST be read against a clock shown inside the window when there is one (for example a remote session's taskbar clock), else the capture's time. Because the Mac's menu-bar clock is not in the picture, the capture's time is an accepted reference here: dates that depend on it MUST NOT be flagged as guesses for that reason alone. The rules of spec 011 for unnamed months and years, and for a clock that differs from the capture time by more than a day, apply unchanged.
- **FR-017**: Findings from a window capture MUST be reconciled with the existing items exactly like findings from a full-screen capture, so an event seen in both kinds of capture is one item with several sightings.
- **FR-018a**: A window capture MUST wait in the analysis queue in the same place as a new full-screen capture: after captures already waiting and ahead of the background re-read of the library (spec 011); it gets no higher priority than a full-screen capture.
- **FR-018**: A window capture MUST flow through every later step like any other capture: text reading, the analysis queue, evidence cut-outs (taken from the window picture), the Inbox rules, search over its text, reprocessing, retention and "Delete everything".

**No change to the full-screen capture**

- **FR-019**: The existing capture shortcut (default Control+Option+Command+M, or the user's own), "Capture now", and the full-screen capture's pictures, confirmation and analysis MUST behave exactly as before this feature.
- **FR-020**: Window and full-screen captures MUST share one rule for double presses and for requests while a capture is running: a double press counts once and a request while any capture runs is ignored.

**Privacy and permission**

- **FR-021**: The window capture MUST use the same Screen Recording permission as the full-screen capture; a refusal MUST change the tracked status and open onboarding, as today (spec 002).
- **FR-022**: Nothing about a window capture (picture, title, application name) MUST leave the Mac.

### Key Entities

- **Capture (extended)**: As in spec 002, plus its scope: all displays or one window, and for a window capture the application name, window title and the window's frame on the desktop.
- **Window picture**: The single picture of a window capture, at native pixel size, standing in for the display pictures of a full-screen capture.
- **Capture outline**: The temporary red border drawn along the recorded area after a successful window capture; it has no stored form.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of window captures, the stored capture holds exactly one picture, and that picture shows only the window that was in front.
- **SC-002**: In 100% of successful window captures, the red border appears within half a second of the shortcut press on a window of ordinary size, matches the outline of the stored picture to within a few points, and disappears by itself within 1.5 seconds; it appears in 0% of stored pictures.
- **SC-003**: On synthetic window pictures, zero items or dates come from text outside the captured window's outline, and items from window captures that repeat items of full-screen captures are merged into the existing items (zero duplicates).
- **SC-004**: The full-screen capture is unchanged: its existing tests pass, and the evaluation scores on the existing golden set do not move (no case loses anything on precision or recall).
- **SC-005**: Analysing a window capture takes no longer than analysing a full-screen capture that shows the same window alone, and on average less than a full-screen capture of a desktop with several windows.
- **SC-006**: The window-capture shortcut works while a remote-desktop client is focused and full screen, as the capture shortcut does (spec 001).
- **SC-007**: When no window qualifies or the permission is missing, 100% of window-capture requests store nothing and show the warning.

## Assumptions

- "Active window" means the window that has keyboard focus in the frontmost application at the moment the request is handled; when the application has no focused window, its main window, else its front-most ordinary window. Memorri's own windows, the menu bar, the Dock and system overlays are never it.
- Memorri does not ask for Accessibility permission for this. The focused window is taken as the front-most ordinary window of the frontmost application, which is the window with keyboard focus except for non-activating panels (plan, research R2).
- When the Memorri menu is open, macOS keeps the frontmost application unchanged, so "Capture window" from the menu captures the window the user was working in.
- The default shortcut Control+Option+Command+W sits next to the existing M (capture) and F (search) defaults and is not one macOS reserves; the user can change it if another app or a remote-desktop client uses it.
- The red border is about 4 points wide, drawn just inside the outline of the recorded area so it stays visible at screen edges, shown for about one second, then faded. Colour, width and duration are not configurable in this spec.
- The capture confirmation settings (icon flash, sound) that exist for the full-screen capture apply to the window capture too; no separate settings are added.
- A window capture is stored with the same layout, format, analysis copy size and retention as one display picture of a full-screen capture (ADR 0009); the analysis treats it like a capture of one display that holds one window filling it.
- The reference clock of spec 011 is unchanged for full-screen captures; FR-016 only covers a picture that holds no menu bar.
- The evaluation set gains synthetic window pictures (a mail, a calendar view, a remote session with its own clock); the existing golden cases are not changed.
- Capturing a window that is not the active one (by picking it or hovering over it) and capturing a region are out of scope.
