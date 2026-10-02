# UI contract: Settings > Calendar sync (spec 009)

1. Access: one row for Calendar and one for Reminders, each with its state and `Allow` or `Open System Settings`.
2. Targets: `Calendar for appointments` and `List for tasks and reminders` pickers (each entry `Name · Account`; `Memorri` preselected when it exists, else none), the note that Memorri works best in a calendar of its own and never touches the others; a notice when the chosen calendar already holds other events. Changing a target shows the move preview first.
3. Switch: `Sync to Calendar and Reminders` (off until both targets are chosen); the range note (`items up to 90 days old`).
4. `Preview` (a sheet: creates, updates, removals, each with the item and the fields), `Sync now`, status line (`Synced 3 min ago`, or the problem).
5. Runs: the last runs with counts and failure reasons. `Remove Memorri's entries` (with confirmation) when switching off.
Item detail: a row `Calendar: synced 14:02 / Reminders: completed / not synced: <reason>`, with `Sync again` after a deletion by the user.
Deep link: `memorri://item/<id>` opens the Items window on the item.
