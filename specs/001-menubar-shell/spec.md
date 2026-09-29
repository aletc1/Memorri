# Feature Specification: Menu-bar shell, hotkey and permissions

**Feature Branch**: `001-menubar-shell`

**Created**: 2026-09-29

**Status**: Draft

**Input**: User description: "Build the Memorri macOS 26+ menu-bar app shell. It shows a menu-bar icon with a menu (Capture now, Inbox, Search, Settings, Quit). A configurable global hotkey (default Control+Option+Command+M) triggers Capture, and the menu item is a fallback. A Settings window skeleton exists. Screen Recording permission onboarding shows the current status and links to System Settings. Local builds use a stable self-signed identity so permissions persist (ADR 0007, 0008). Acceptance: the hotkey works while a remote-desktop client is focused and full-screen; permission survives a rebuild."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trigger a capture from the menu bar (Priority: P1)

The user launches Memorri and sees its icon in the menu bar, with no Dock icon and no main window. Clicking the icon opens a menu with Capture now, Inbox, Search, Settings and Quit. Choosing Capture now requests a capture.

**Why this priority**: The menu bar is the app's only entry point. Every later capability is reached from it, and it is the guaranteed fallback when the hotkey does not work.

**Independent Test**: Launch the app, click the icon, choose each menu item, and confirm the expected reaction. Delivers a running app that later specs extend.

**Acceptance Scenarios**:

1. **Given** the app has just launched, **When** the user looks at the menu bar, **Then** the Memorri icon is visible and no Dock icon or window appears.
2. **Given** the menu is open, **When** the user chooses Capture now, **Then** the app records a capture request and gives visible feedback that it was received.
3. **Given** the menu is open, **When** the user chooses Settings, **Then** the Settings window opens and comes to the front.
4. **Given** the menu is open, **When** the user chooses Inbox or Search, **Then** a placeholder window for that feature opens and states that the feature is not built yet.
5. **Given** the menu is open, **When** the user chooses Quit, **Then** the app exits and its icon disappears.

---

### User Story 2 - Trigger a capture with a global hotkey (Priority: P1)

From any application, the user presses a keyboard shortcut (default Control+Option+Command+M) and Memorri requests a capture, without switching apps. The user can change the shortcut in Settings.

**Why this priority**: The hotkey is the primary way to capture while working in another window, and its reliability inside remote-desktop sessions is the central risk of the whole product.

**Independent Test**: With another app in front, press the default shortcut and confirm the capture request feedback. Change the shortcut in Settings and confirm only the new one works.

**Acceptance Scenarios**:

1. **Given** Memorri is running and another app is focused, **When** the user presses the default shortcut, **Then** a capture request is recorded with the same feedback as Capture now.
2. **Given** a remote-desktop client is focused and full-screen, **When** the user presses the shortcut, **Then** a capture request is recorded.
3. **Given** the user opens Settings, **When** they record a new shortcut, **Then** the new shortcut works immediately and the old one no longer does.
4. **Given** the user records a shortcut already reserved by macOS or already used by another Memorri action, **When** they confirm it, **Then** the app warns and keeps the previous shortcut.
5. **Given** the user has changed the shortcut, **When** they quit and relaunch the app, **Then** the chosen shortcut is still in effect.
6. **Given** the user chose a shortcut, **When** they choose Reset to default, **Then** the default shortcut is restored.

---

### User Story 3 - Grant and monitor Screen Recording permission (Priority: P1)

On first launch, and whenever the permission is missing, the user sees a clear status of the Screen Recording permission and a way to grant it. Once granted, the status shows as granted and the permission keeps working across rebuilds and relaunches.

**Why this priority**: Without this permission no capture can ever work, and losing it silently after each rebuild would make development and daily use unreliable.

**Independent Test**: Launch with permission not granted, follow the onboarding to System Settings, grant it, and confirm the status updates. Rebuild and relaunch the app and confirm the permission is still granted.

**Acceptance Scenarios**:

1. **Given** the permission has not been granted, **When** the app launches, **Then** an onboarding view explains why it is needed and shows the status as not granted.
2. **Given** the onboarding is showing, **When** the user chooses to open System Settings, **Then** the Screen Recording pane of System Settings opens.
3. **Given** the user grants the permission in System Settings, **When** they return to Memorri, **Then** the status updates to granted without needing to reopen Settings.
4. **Given** macOS requires an app restart for the permission to take effect, **When** the permission has just been granted, **Then** the app tells the user and offers to relaunch.
5. **Given** the permission is granted, **When** the developer rebuilds the app with the local signing setup and relaunches it, **Then** the permission is still granted and no prompt reappears.
6. **Given** the permission is not granted, **When** the user chooses Capture now or presses the shortcut, **Then** the app shows the permission status instead of failing silently.

---

### User Story 4 - Settings window skeleton (Priority: P2)

The user opens Settings and finds an organised window with sections for General (shortcut, launch behaviour), Permissions (status), and placeholder sections for later features (Ollama, Storage, Calendar sync).

**Why this priority**: Later specs each add their own settings. A stable skeleton avoids reworking navigation, but it is not needed to capture.

**Independent Test**: Open Settings, move between sections, close and reopen it, and confirm each section shows what it should.

**Acceptance Scenarios**:

1. **Given** the user opens Settings, **When** the window appears, **Then** it lists the General, Permissions and placeholder sections and shows General first.
2. **Given** a placeholder section is selected, **When** it is displayed, **Then** it states which future feature will fill it.
3. **Given** Settings is already open, **When** the user chooses Settings again, **Then** the existing window comes to the front instead of a second one opening.

---

### Edge Cases

- The chosen shortcut is swallowed by the focused application (some remote-desktop clients forward all keys to the remote session): the menu-bar item still works, and the user can pick another shortcut.
- The shortcut is pressed twice quickly: only one capture request is recorded per intended press, and none is lost.
- The permission is revoked in System Settings while the app is running: the status changes to not granted within a few seconds or on next interaction.
- Two copies of the app are launched: the second one exits or hands over to the first, so there is one menu-bar icon.
- The menu-bar icon is hidden because the menu bar is crowded or the user has a notch: the shortcut and Settings remain reachable.
- The app is started with more than one display connected, or with a display in full-screen: the menu and Settings open on the active display.
- The signing identity is missing on a developer machine: the build fails with a message that points to the setup script, not a silent ad-hoc signature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST run as a menu-bar-only app, with an icon in the menu bar and no Dock icon or main window.
- **FR-002**: The menu MUST offer Capture now, Inbox, Search, Settings and Quit.
- **FR-003**: Capture now and the global shortcut MUST both produce a capture request through the same path, so later specs attach the real capture to a single point.
- **FR-004**: The app MUST give visible feedback when a capture request is received, and MUST record it so it can be verified in tests.
- **FR-005**: The global shortcut MUST default to Control+Option+Command+M and MUST work when any other application is focused, including a full-screen remote-desktop client.
- **FR-006**: The user MUST be able to change, clear and reset the shortcut in Settings, and the choice MUST persist across launches.
- **FR-007**: The app MUST reject a shortcut that conflicts with a reserved macOS shortcut or with another Memorri action, and MUST explain why.
- **FR-008**: The app MUST show the current Screen Recording permission status and update it when it changes.
- **FR-009**: The app MUST offer a one-step way to open the Screen Recording pane of System Settings and explain why the permission is needed.
- **FR-010**: When a capture is requested without the permission, the app MUST show the permission status instead of failing silently.
- **FR-011**: The app MUST tell the user when a restart is needed for a newly granted permission and offer to relaunch.
- **FR-012**: The Settings window MUST provide General and Permissions sections and placeholder sections for Ollama, Storage and Calendar sync, and MUST open a single instance.
- **FR-013**: Inbox and Search MUST open placeholder windows that say the features are not built yet.
- **FR-014**: The app MUST run as a single instance.
- **FR-015**: Local builds MUST be signed with the stable local identity described in ADR 0007 so that the Screen Recording permission survives rebuilds, and the build MUST fail with a clear message if the identity is missing.
- **FR-016**: The project MUST be generated from a declarative project definition and MUST build and run with the documented commands, with the logic separated into a local package as described in ADR 0002.
- **FR-017**: The app MUST NOT send any data over the network.

### Key Entities

- **Capture request**: A recorded intent to capture, with a timestamp and its trigger (menu or shortcut). Spec 002 turns it into a real capture.
- **Shortcut setting**: The user's chosen key combination for Capture, or none.
- **Permission status**: One of granted, not granted, or restart required, for Screen Recording.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From launch, the user sees the menu-bar icon within 2 seconds and can trigger a capture request in one click or one key press.
- **SC-002**: In 20 consecutive presses of the shortcut across at least three different focused apps, including a full-screen remote-desktop client, at least 19 produce a capture request and none produce a duplicate.
- **SC-003**: A developer can rebuild and relaunch the app 5 times in a row and Screen Recording stays granted every time, with no permission prompt.
- **SC-004**: A user with no prior knowledge can go from first launch to a granted permission in under 2 minutes using only the onboarding.
- **SC-005**: A changed shortcut takes effect immediately and is still in effect after 3 relaunches.
- **SC-006**: A new developer can build and run the app from a clean checkout by following the developer guide only, in under 15 minutes.

## Assumptions

- The app targets macOS 26 or later, as decided in ADR 0002.
- "Capture" in this spec only records a capture request and shows feedback. Taking the actual screenshot and storing it is spec 002.
- Inbox and Search are placeholders in this spec. Real content comes in specs 006 and 007.
- The app is for one user on one Mac and is never notarized or distributed, so the local signing identity from ADR 0007 is enough.
- The shortcut library and default key combination are decided in ADR 0008. If a remote-desktop client swallows the default, the user picks another shortcut. There is no attempt to work around a client that captures the keyboard entirely.
- The user has already run the signing script `scripts/create-signing-certificate.sh` on the developer machine.
- Launch at login and notifications are out of scope, and come in spec 010.
- Testing the remote-desktop scenario is manual, using the user's real client, because it cannot be reproduced in an automated test.
