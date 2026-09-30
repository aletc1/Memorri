# Feature Specification: Capture every display and keep the captures

**Feature Branch**: `002-capture-and-storage`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "Capture every display separately with ScreenCaptureKit on hotkey, store full-resolution HEIC images plus a downscaled copy for the model (configurable long edge, default 2048). Create the GRDB database, migrations, and the raw capture_events and capture_images tables. Settings shows storage used, offers cleanup by age or everything, and a retention policy. Excluded from Time Machine. The real capture call is the source of truth for the Screen Recording permission: a failed capture changes the tracked status and opens the onboarding window (see docs/postmortems/2026-09-29-permission-and-launch-assumptions.md)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Capture every display with one action (Priority: P1)

The user presses the capture shortcut, or chooses Capture now, while working, for example in a full-screen remote-desktop session. Memorri takes one picture of each connected display, each on its own, and keeps them. The user gets the same flash and sound as before, now meaning that the pictures were really taken and saved.

**Why this priority**: This is the core of the product. Nothing can be read, inferred or searched until screens are captured and kept.

**Independent Test**: With two displays connected, press the shortcut and confirm that two separate picture sets are stored, each matching its display, and that the feedback plays after they are saved.

**Acceptance Scenarios**:

1. **Given** two displays are connected and permission is granted, **When** the user presses the shortcut, **Then** one full-resolution picture per display is stored, plus one smaller copy per display for analysis, and the feedback plays.
2. **Given** the user chooses Capture now from the menu, **When** the capture finishes, **Then** the result is the same as with the shortcut.
3. **Given** one display is showing a full-screen application, **When** the user captures, **Then** that display's picture shows the full-screen content at its real size.
4. **Given** a capture is already running, **When** the user requests another, **Then** the second request is ignored and the running capture is not disturbed.
5. **Given** a display is larger than the analysis size, **When** the capture is stored, **Then** the analysis copy is reduced so its longer side equals the configured size, and the full-resolution picture is untouched.
6. **Given** a display is smaller than the analysis size, **When** the capture is stored, **Then** the analysis copy is not enlarged.

---

### User Story 2 - A failed capture is reported and fixes the permission state (Priority: P1)

If macOS refuses the capture because Screen Recording is missing or was switched off, the app finds out from the real attempt, not from a guess. The permission status changes to "not granted", the onboarding window opens, and nothing half-saved is left behind.

**Why this priority**: Earlier testing showed a running app cannot see permission changes by itself. The capture attempt is the only fully reliable signal, and users must not be told a capture worked when it did not.

**Independent Test**: Revoke the permission while the app runs (so it still believes it is granted), press the shortcut, and confirm the status flips, the onboarding window opens, no pictures are stored and no success feedback plays.

**Acceptance Scenarios**:

1. **Given** the permission was revoked while the app runs, **When** the user captures, **Then** the attempt fails, the status becomes "not granted" within 2 seconds, the onboarding window opens, and no success feedback plays.
2. **Given** a capture failed for lack of permission, **When** the user looks at the stored data, **Then** no pictures from that attempt remain, and the attempt is recorded as failed.
3. **Given** the permission is granted and one of two displays cannot be captured, **When** the user captures, **Then** the working display's pictures are kept, the attempt is recorded as partial, and the user is told that one display could not be captured.
4. **Given** a capture fails for another reason (for example no disk space), **When** the user captures, **Then** the user sees a short message saying what went wrong, nothing half-saved remains, and the permission status is not changed.
5. **Given** a capture succeeded, **When** the permission status was wrongly shown as "not granted" or "restart required", **Then** the status becomes "granted".

---

### User Story 3 - Captures are kept safely and survive restarts (Priority: P1)

Every capture is kept as a record of the request and its pictures. The records and pictures live in one private folder on the Mac, are not copied into backups, and are still there after quitting and relaunching the app. The storage can change shape over time without losing data.

**Why this priority**: Later specs read, analyse and re-analyse these captures. Losing or leaking them would break the product's privacy promise.

**Independent Test**: Make three captures, quit and relaunch the app, and confirm all three are still stored; then confirm the data folder is private and excluded from backups.

**Acceptance Scenarios**:

1. **Given** the first capture ever, **When** it is saved, **Then** the data folder and storage are created automatically.
2. **Given** captures exist, **When** the app is quit and relaunched, **Then** every capture and its pictures are still there.
3. **Given** the data folder, **When** another user account on the Mac tries to read it, **Then** access is denied.
4. **Given** the data folder, **When** the system backup is configured, **Then** the folder is reported as excluded from backups.
5. **Given** a newer version of the app changes how data is stored, **When** it starts, **Then** existing data is upgraded without loss, and an older app version that meets data from a newer one does not modify it and says so.
6. **Given** a picture file was deleted by hand, **When** the app starts, **Then** the capture is marked as having a missing picture instead of failing, and pictures with no record are removed.

---

### User Story 4 - See how much space captures use and clean up (Priority: P2)

In Settings, the Storage section shows how many captures exist and how much space they use. The user can delete captures older than a chosen number of days, or delete everything, after a confirmation that says exactly what will be removed.

**Why this priority**: Screenshots of work sessions are large and sensitive. The user must be able to see and control what stays on the Mac.

**Independent Test**: Open Storage, note the numbers, delete captures older than a cutoff, and confirm that only older captures and their pictures are gone and the numbers update.

**Acceptance Scenarios**:

1. **Given** captures exist, **When** the user opens Storage, **Then** it shows the number of captures and the space used by pictures and by records.
2. **Given** captures of different ages, **When** the user chooses "delete older than N days" and confirms, **Then** only captures older than N days are removed, together with their pictures, and the numbers update.
3. **Given** captures exist, **When** the user chooses "delete everything" and confirms, **Then** all captures and pictures are removed and the numbers show zero.
4. **Given** a cleanup is offered, **When** the user sees the confirmation, **Then** it states how many captures and how much space will be freed, and cancelling changes nothing.
5. **Given** a capture is running, **When** the user starts a cleanup, **Then** the running capture is not removed.

---

### User Story 5 - Keep captures only as long as the user wants (Priority: P2)

The user sets a retention policy in Settings: keep captures forever, or delete those older than a chosen number of days. The policy is applied automatically, so the user does not have to remember to clean up.

**Why this priority**: Automatic expiry is the safest default for sensitive screen content.

**Independent Test**: Set the policy to 1 day with captures older than that present, relaunch the app, and confirm the old captures are gone and newer ones stay.

**Acceptance Scenarios**:

1. **Given** the default settings, **When** the user opens Storage, **Then** the retention policy shows 30 days.
2. **Given** a policy of N days, **When** the app starts, **Then** captures older than N days are removed.
3. **Given** a policy of N days and the app running for days, **When** a day passes, **Then** expired captures are removed without any action.
4. **Given** the policy is "keep forever", **When** the app starts, **Then** nothing is removed automatically.
5. **Given** the user shortens the policy, **When** they confirm, **Then** the change applies at once and says how many captures will be removed before it does.

---

### User Story 6 - Choose the size of the analysis copy (Priority: P3)

The user can change the longer side, in pixels, of the smaller copy kept for analysis. It applies to future captures. The default is 2048.

**Why this priority**: The best size trades quality against speed and is settled later by measurement (spec 004). The setting lets that be tuned without a new version.

**Independent Test**: Set the size to 1024, capture, and confirm the analysis copy's longer side is 1024; set it back to the default and confirm 2048.

**Acceptance Scenarios**:

1. **Given** the default settings, **When** the user opens Storage, **Then** the analysis copy size shows 2048 pixels.
2. **Given** the user sets a new size within the allowed range, **When** they capture, **Then** the analysis copy uses it, and earlier captures are unchanged.
3. **Given** the user enters a size outside the allowed range, **When** they confirm, **Then** the app explains the range and keeps the previous value.

---

### Edge Cases

- A display is connected or disconnected during a capture: the displays present when the capture started are captured; one that disappears counts as a failed display (partial capture).
- Two displays show the same content (mirrored): each distinct display is captured once, so a mirror pair gives one capture, not two.
- There is no display available (for example the lid is closed with nothing attached): the request fails with a short message and nothing is stored.
- The disk is full or nearly full: the capture fails with a clear message and leaves nothing half-saved; existing captures are untouched.
- A very large display (for example 8K): capturing still completes without the app becoming unresponsive, and the menu and Settings stay usable.
- The screen is locked, or content is protected by the system or an application and appears black: it is captured as shown, and the app does not try to get around protection.
- The permission is revoked while a capture is running: the capture fails as in User Story 2 and leaves nothing half-saved.
- The user quits the app during a capture: nothing half-saved remains at the next start.
- The data folder is deleted while the app runs: the next capture recreates it, and the app does not crash.
- The database file is damaged: the app does not delete it, tells the user, and keeps capturing into a new one after a clear message (the damaged file is set aside, not destroyed).
- A cleanup or retention run and a new capture happen at the same time: neither corrupts the other, and the new capture is kept.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A capture request MUST take one separate picture of each connected display (one per distinct display; mirrored displays count once), each at the display's full native resolution.
- **FR-002**: Capture now and the global shortcut MUST both start the same capture through the capture request path from spec 001.
- **FR-003**: Each capture request that reaches the capturing step MUST be recorded as one capture event with its time, its trigger (menu or shortcut), its result (complete, partial or failed) and the pictures it produced.
- **FR-004**: For each display the app MUST store a full-resolution picture in a space-efficient format and a smaller analysis copy whose longer side equals the configured size, never enlarging a picture that is already smaller.
- **FR-005**: The analysis copy size MUST be settable in Settings within 512 to 4096 pixels, default 2048, and MUST apply only to later captures.
- **FR-006**: The success feedback (icon flash and sound, as configured in spec 001) MUST play only after at least one display's pictures have been stored.
- **FR-007**: When macOS refuses a capture because Screen Recording is missing or revoked, the app MUST set the permission status to "not granted", open the onboarding window, play no success feedback, keep no pictures from that attempt, and record the event as failed.
- **FR-008**: When some displays are captured and others fail, the app MUST keep the successful pictures, record the event as partial, and tell the user how many displays could not be captured.
- **FR-009**: When a capture fails for any other reason, the app MUST show a short message saying what went wrong, leave nothing half-saved, and leave the permission status unchanged.
- **FR-010**: A successful capture MUST set the permission status to "granted".
- **FR-011**: A capture request made while another capture is running MUST be ignored.
- **FR-012**: All records and pictures MUST be kept in one folder under the user's Application Support area, readable only by the current user, and excluded from system backups.
- **FR-013**: Storage MUST be created on first use, MUST upgrade without data loss when a newer app version changes its shape, and MUST NOT be modified by an older app version that finds data from a newer one (the app says so instead).
- **FR-014**: At start the app MUST reconcile records and files: a record whose picture file is missing is marked as such, and a picture file without a record is removed.
- **FR-015**: Settings MUST have a Storage section (replacing the placeholder from spec 001) showing the number of captures and the space used by pictures and by records, refreshed whenever it is opened.
- **FR-016**: Settings MUST offer "delete older than N days" and "delete everything", each after a confirmation that states how many captures and how much space are affected, and each removing records and pictures together; a capture in progress MUST NOT be removed.
- **FR-017**: Settings MUST offer a retention policy, either "keep forever" or "delete older than N days", default 30 days, applied at start and once a day while the app runs.
- **FR-018**: Shortening the retention policy MUST state how many captures it will remove before applying.
- **FR-019**: A damaged database MUST NOT be deleted; it is set aside, the user is told, and capturing continues with a new one.
- **FR-020**: The app MUST NOT send any data over the network.

### Key Entities

- **Capture event**: One capture request that reached the capturing step. Has a time, a trigger (menu or shortcut), a result (complete, partial or failed), a short failure reason when it did not fully succeed, and the pictures it produced. Later specs attach analysis to it.
- **Capture image**: The pictures of one display within one capture event: which display it was, its size in pixels and scale, a full-resolution picture and an analysis copy, and their sizes on disk. A missing-file marker when a file has been lost.
- **Storage settings**: The analysis copy size (512 to 4096, default 2048) and the retention policy (keep forever, or N days, default 30).
- **Storage summary**: What Settings shows: number of captures, space used by pictures, space used by records.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With up to three displays, the success feedback plays within 2 seconds of pressing the shortcut.
- **SC-002**: In 20 consecutive captures with at least two displays, every capture produces exactly one full-resolution picture and one analysis copy per distinct display, with none missing or duplicated.
- **SC-003**: Every analysis copy has a longer side equal to the configured size when its display is larger, and is never larger than its original.
- **SC-004**: After revoking Screen Recording while the app runs, the next capture stores nothing, opens the onboarding window within 2 seconds, and the permission status reads "not granted", in every one of 5 trials.
- **SC-005**: After quitting and relaunching 3 times, the number of captures and their pictures is identical each time.
- **SC-006**: The figures in Storage match the actual space used on disk within 1%.
- **SC-007**: After "delete older than N days", 100% of captures older than N days are gone with their files and 100% of newer ones are untouched; after "delete everything", no capture records or files remain.
- **SC-008**: The data folder is reported by the system as excluded from backups, and another user account cannot read it.
- **SC-009**: The menu and Settings remain usable (respond within 1 second) while a capture of the largest connected displays is in progress.

## Assumptions

- Builds on spec 001: the capture request path, the feedback settings, the permission status tracking and the onboarding window already exist. "Capture" now does real work.
- Analysis of the pictures (reading text, finding appointments) is out of scope here and arrives in specs 003 and 004. This spec only captures and keeps.
- The default retention is 30 days. Screenshots of work sessions are sensitive, so automatic expiry is the safer default. The user can change it or keep everything.
- The analysis copy size is a setting because the best value is settled later by measurement (spec 004).
- Protected content that the system shows as black is captured as shown; bypassing protection is not attempted.
- The Memorri windows are captured like any other window if they are on screen.
- Captures are not encrypted by the app. Protection relies on the private folder and disk encryption of the Mac (FileVault); encrypting at rest may come later.
- Pictures are stored per display; combining displays into one picture is not done, to keep full resolution.
- The Storage section replaces the "Storage" placeholder shown in Settings since spec 001.
- Testing with multiple displays and revocation is manual on a real Mac, using the automation available on the developer machine where possible.
