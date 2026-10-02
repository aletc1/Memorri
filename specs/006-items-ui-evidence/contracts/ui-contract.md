# UI contract: evidence, editing, Inbox

Extends [spec 005's UI contract](../../005-reconciliation/contracts/ui-contract.md).

## Menu
`Inbox` becomes `Inbox (N)` when N > 0 items need review, and opens the Items window on the Inbox scope. The `Inbox` placeholder window is removed.

## Items window
- Above the list: a scope control `Items · Inbox (N)`. Inbox shows only items needing review, newest first, each with its reasons as small labels (`Low confidence`, `Guessed time`, `Guessed end`, `Guessed due date`, `Possible duplicate`, `Changed after you approved it`). Empty Inbox: `Nothing needs review.`
- Kind filter: `All · Appointments · Tasks · Reminders`. Context filter as before.
- Rows: kind symbol, title, date and time, context, sightings, lock mark, and an approval mark (`Needs review` orange dot; nothing for approved).
- Toolbar adds `Approve` when every selected item needs review (Return approves in the Inbox; ⌫ dismisses).

## Detail
- Header: approval state with `Approve` when it needs review.
- `Fields`: each field shows its value, source (`read` / `guessed` / `you`) and lock; clicking the value (or Return with it focused) edits it in place:
  - title, place: text field; notes: multi-line; people: comma-separated names;
  - start, end, due, reminder: date and time picker in the item's zone; all-day: toggle;
  - Return or `Save` confirms, Esc cancels, an invalid value shows a red message under the field and keeps the old value.
  - A field with no value shows `Add`.
- `Evidence`: the 5 newest sightings as cards: the cut-out (or `No cut-out: the finding cited no lines`), capture date and time, display, title as found, confidence, `why`; `Show whole capture` opens a sheet with the full picture, the region and cited lines outlined (or `The capture is no longer stored.`). `Show all N sightings` below.
- Split checkboxes move to the cards.

## Settings → Storage
Adds `Evidence: <size>` under the pictures figure. The `Delete everything` confirmation says it also removes evidence cut-outs.

## Log lines (category `evidence`)
- `evidence image=<id> written=<n> skipped=<n> ms=<n>`; `evidence backfill written=<n>`; `evidence failed image=<id> reason=<short>` (no text, no titles).

## As built (differences from the plan above)

- The scope control has three segments: `Items`, `Inbox (N)` and `Approved`. N is the number the Inbox lists with the current kind and context filters; the menu's `Inbox (N)` counts every context.
- Rows show the reasons in orange under the line of context and sightings; there is no separate approval mark for approved items. Return approves and ⌫ dismisses only while the list has focus in the Inbox scope; after an approval the selection moves to the next item.
- The title is edited in `Fields` like every other field (the header shows it as text). A field row shows a pencil (or a double-click on the value) and, when more than one value was seen or it is locked, a chevron that lists every value behind it with its source, confidence and time and marks the current one (FR-005). The evidence card of the sighting that gave the current title says `Source of the current title`.
- Date fields use a date and time picker in the item's zone with `Save`, `Cancel` and, for optional fields, `Clear`; text fields use `parse`, so a rejected value shows its message under the field.
- The window's `Kind` control is `All · Appointments · Tasks · Reminders`; `Tasks` includes deadlines.
- Clicking a cut-out opens the whole capture (the same sheet as `Show whole capture`); a cut-out shows the context around the cited lines, not only the lines.
- The whole-capture sheet takes 80% of the screen and can be zoomed (buttons `-`, `Fit`, `100%`, `+`, ⌘- and ⌘=, or pinch) and scrolled.
