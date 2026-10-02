feat(sync): copy ready items to a Calendar and a Reminders list of the user's choosing (spec 009)

## What
- Settings > Calendar sync: allow Calendar and Reminders, choose the calendar for appointments and the list for tasks and reminders (a calendar or list named `Memorri` is preselected; Memorri never creates one), switch sync on, read the preview, press `Sync now`. Items that are ready (not waiting in the Inbox, up to 90 days old) are then copied automatically a few seconds after they change.
- Memorri writes only in the chosen calendar and list, and only entries it made. Personal, Work and every other calendar or list are never changed.
- Dismissed or merged items are removed from Calendar; restoring writes them again. A time or place changed in Calendar is taken into the item as the user's own value (locked, shown in the history as made in Calendar). A reminder completed in Reminders stays completed. An entry the user deleted is not recreated; the item shows why and offers `Sync again`.
- Preview shows what a sync would create, update, move or remove and writes nothing. Runs are kept (last 20). Switching off can keep or remove Memorri's entries. Changing the chosen calendar asks before moving entries.
- The item detail shows where the item is in Calendar or Reminders. `memorri://item/<id>` in the notes opens the item.

## Why
The items Memorri finds belong where the user already looks at their day, on every device, without mixing them into the calendars synced with work.

## Design
A pure `SyncPlanner` over a `ScopedEventStore` that refuses any write outside the chosen targets or any entry not in `sync_links` (ADR 0026); migration v11 (`sync_links`, `sync_runs`); the link keeps the entry as the store returned it, so a round-trip difference is never taken for an edit; all-day entries are carried as calendar days.

Spec: `specs/009-eventkit-sync/`. ADRs: 0006, 0026.

## Verification
- `swift test --package-path Packages/MemorriCore`: 1435 tests pass; new suites for the guard, targets, render and hash, planner, engine (second run writes nothing, foreign calendars untouched, one failure does not stop others, outside edits, completion, deletion, moves, a store that keeps fields differently), coordinator (held first run, debounce, no overlap) and the 1,000-item scale test.
- Run in the app against a calendar and a list named `Memorri`: see the end of this description (to be completed after the real run).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
