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
