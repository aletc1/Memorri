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
