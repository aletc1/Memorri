# UI contract: Items window

## Menu

The menu bar menu gains `Items…` above `Inbox`, opening the Items window (window id `.items`, title `Memorri Items`, resizable, size remembered, default 900 × 600).

## Items window

A split view.

**List (left)**
- Filter bar: kind segmented control `All · Appointments · Tasks & reminders`, a context menu (`All contexts`, each context, `No context`), and a toggle `Show dismissed`.
- Rows sorted by start or due date, then title: kind symbol, title, date and time in the item's time zone (or `No date`), context name, `N sightings`, a `Possible duplicate` badge when one is open, and a lock symbol when any field is locked. Dismissed rows are greyed.
- Multiple selection. With two items selected the toolbar shows `Merge`.
- Toolbar: `Merge` (two selected), `Dismiss` / `Restore`, `Undo last` (undoes your newest operation not yet undone, never an automatic merge; disabled when none).
- Empty state: `No items yet. Items appear after captures are analysed.`

**Detail (right)** for one selected item:
- Header: editable title (Return saves, writes a locked user observation), kind, times, context, status.
- `Fields`: one row per field with its value, `read` / `guessed` / `you` source, and a lock button for locked fields (`Unlock` asks nothing).
- `Sightings`: one row per sighting: capture date and time, display, title as found, confidence, `why` (rule and scores). Checkboxes and `Split into new item` (needs at least one unchecked sighting left).
- `Other titles`: the aliases.
- `Possible duplicates`: the other item with `Merge` and `Different`.
- `History`: operations on this item, newest first, each with `Undo` (disabled after it is undone; a partial undo shows its reason).

**Merge with conflicting locks**: a sheet `Both items have your value for <field>. Keep:` with the two values; Cancel aborts the merge.

All actions run on the core off the main actor; the list updates from the store's observation. Errors show an inline message in the window; nothing is lost.

## Settings → Ollama (edit)

A `Matching models` group with two pickers, `Meaning (embeddings)` and `Same-event judge (reranker)`, listing installed models plus `None`. Defaults: the e5 and reranker model names from research R3 and R4 when installed, otherwise `None`. Note: `With None, Memorri matches on text and time only and flags unclear pairs as possible duplicates.`

## Log lines (subsystem `com.aletc1.memorri`, category `reconcile`)

- `reconciled image=<id> findings=<n> created=<n> merged=<n> possible=<n> judged=<n> ms=<n>`
- `reconcile failed image=<id> reason=<short>` (no titles in logs)
- `op <kind> items=<n> op=<id>` and `undo op=<id> result=<undone|partly|impossible>`
