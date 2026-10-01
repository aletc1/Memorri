# Quickstart: validate evidence, editing and the Inbox

Prerequisites: a Debug build, Ollama with `qwen3-vl:8b-instruct`, an isolated home (`CFFIXED_USER_HOME=<scratch dir>`), and synthetic cases only (`--ingest-case eval/golden/synthetic/<case>`).

1. **Core tests**: `swift test --package-path Packages/MemorriCore` passes, including geometry, review rules, writer, approve/edit undo and the scale test.
2. **Evidence**: ingest `calendar-week-web-12h`; open an item. Expected: each sighting card shows a cut-out with the title's block; `Show whole capture` outlines the cited lines (SC-001, SC-002).
3. **Deleted capture**: Settings → Storage → delete captures older than 0 days (retention path). Expected: items you edited stay with their cut-outs; `Show whole capture` says it is no longer stored. Then `Delete everything`: cut-outs are gone and the Evidence figure is 0.
4. **Inbox**: ingest `chat-teams-tomorrow` (guessed end) and `calendar-week-outlook-24h-blocks`. Expected: only items with guessed times or low confidence are in `Inbox (N)`; the menu shows the same N; Approve removes one; Undo last brings it back (SC-003, SC-006).
5. **Changed after approval**: approve an item, ingest a case with the same event at another end time. Expected: it is back in the Inbox with `Changed after you approved it`.
6. **Inline editing**: change start, place, people and notes of an item; enter an end before the start. Expected: valid edits show `you` and a lock and approve the item; the invalid one shows a message and keeps the old value; re-ingesting the case does not change the edited values; Unlock restores the read value (SC-005, SC-008).
7. **Filters**: Appointments, Tasks and Reminders each list only their kind; the context filter applies to the Inbox.
8. **Scale**: the scale test reports opening an item's evidence under 1 s and the Inbox under 0.5 s with 5,000 items (SC-007).

## Results

### US1: evidence (2026-10-01)

Debug build, `CFFIXED_USER_HOME` set to a scratch folder, `qwen3-vl:8b-instruct`, drawn pictures only (`calendar-week-web-12h` ingested twice).

- **2 Evidence**: log lines `evidence image=… written=3 skipped=0 ms=111` and `… ms=118` after the two `reconciled` lines. The Items window showed, for "Dentist Clinic" (2 sightings), a card per sighting with a cut-out showing the block "9:00 AM Dentist Clinic", the capture date, time and display, the title as found, the confidence and `why: text-time (text 1.00, time 1.00)`. As expected.
- **Show whole capture**: not pressed in the app. Buttons in this window have no accessibility name, and pressing by screen position is off the table after the stray click of spec 005; the sheet is therefore not seen on screen. Its data comes from `EvidenceStore.capture` (tested: picture, lines, nil once the picture is missing). Known gap: look at the sheet by hand once.
- **3 Deleted capture**: not driven through Settings (buttons not reachable by name). Covered by `EvidenceLifecycleTests`: retention keeps the cut-out and its item, the whole capture is then unavailable, `Delete everything` removes every row and file and the Evidence figure goes to 0, the preview counts evidence bytes.

### US2: Inbox and approve (2026-10-01)

Debug build compiled with no warnings. Scenarios 4 and 5 were **not driven in the app**: a copy of Memorri was already running on the user's real data folder, and the single-instance guard makes a second (isolated-home) copy quit at once, so an isolated run was only possible by quitting the user's copy or touching real data. Neither was done.

- **4 Inbox**, covered by tests instead: `ReviewStateTests` (a guessed end puts a 0.9-confidence item in the Inbox; the count equals the rows needing review, per context; dismiss, restore, mark different, merge, split, undo and a re-analysis keep the columns right), `ApproveTests` (approve, undo of approve restores the Inbox state exactly), `ItemListModelTests` (Inbox scope newest first, Approve offered only when every selected item needs review, empty text). The menu count belongs to US4.
- **5 Changed after approval**, covered by `ApproveTests.aLaterSightingThatChangesAnUnlockedApprovedValueReturnsTheItemToTheInbox` (reason `changed-after-approval`, unlocked value still updates, approval kept) and `aLaterSightingDoesNotChangeALockedFieldOrBringTheItemBack`.
- Known gap: look at the Inbox scope control, the reason labels, Approve, Return and ⌫ by hand once.

### US3: inline editing (2026-10-01)

Debug build compiled with no code warnings (the only build message is Xcode's "Metadata extraction skipped, no AppIntents.framework dependency found"). Scenario 6 was **not driven in the app**, for the reason given under US2 (the user's own copy owns the running instance and the real data folder; typing into the app cannot be automated either). The typing paths are covered by tests:

- `ItemOperationsTests`: blank title (`emptyTitle`), start after end and end before start (`startAfterEnd`), equal start and end accepted, people trimmed and de-duplicated, `null` clears place, notes, end, due and reminder as a locked empty value that later sightings do not refill, the edit approves in the same transaction, one Undo restores field, lock and approval together, two edits undo one at a time, an edit confirmed between plan and apply keeps the user's value.
- `ItemListModelTests`: `parse` in the item's own zone, invalid dates, clearing, people, all-day, and `editText` round-trips through `parse`.
- `EditLockTests`: edited start, place, people and notes survive a later capture showing the old values and stay locked; the other values stay visible as observations; Unlock gives the sightings' value back and `fieldText` says where it comes from.
- Known gap: use the editors by hand once (date pickers in a zone other than the Mac's, Return/Esc, the red message).
