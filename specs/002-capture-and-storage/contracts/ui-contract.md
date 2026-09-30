# UI Contract: spec 002

What the user sees. Changes to the spec 001 contract (menu, onboarding) are marked.

## Menu (changes)

A new first line, disabled (not clickable), above "Capture now":

| State | Text |
|---|---|
| no capture since launch | `No capture yet` |
| complete | `Last capture: complete, <age>` |
| partial | `Last capture: 2 of 3 displays captured, <age>` |
| failed | `Last capture failed: <reason>, <age>` |

`<age>` is relative ("just now", "2 min ago", "3 h ago") and refreshes about every 30 seconds. Reasons use these exact texts: `Not enough free disk space`, `no display available`, `could not save the pictures`, or a short system message. A capture refused for lack of permission shows no line; the onboarding window opens instead (spec 001).

## Feedback (change)

| Outcome | Flash | Sound |
|---|---|---|
| complete | existing flash | existing sound ("Pop") |
| partial, failed | warning flash (icon shown in a warning look for about 600 ms) | warning sound ("Basso") |
| permission refused | none | none (onboarding opens) |

Both follow the two existing switches in Settings → General.

## Settings → Storage (replaces the placeholder)

Top to bottom:

1. **Summary**: `<N> captures`, `Pictures: <size>`, `Database: <size>`. Refreshed every time the section is opened.
2. **Retention**: a picker `Keep captures`: `Forever` or `For <n> days` (default 7). Text below: "Captures are the raw screenshots. Appointments, tasks and reminders found in them are always kept."
3. **Analysis copy size**: a number field `Longer side of the analysis copy (pixels)`, range 512 to 4096, default 2048, with the note "Applies to new captures." Out of range shows `Enter a value between 512 and 4096.` and keeps the previous value.
4. **Clean up**: a field `Delete captures older than <n> days` with a button **Delete…**, and a button **Delete all captures…**.

### Confirmations

Each deletion shows a dialog, cancel is the default:

| Action | Text |
|---|---|
| older than N days | `Delete <X> captures older than <N> days? This frees <size> and cannot be undone. Appointments, tasks and reminders found in them are kept.` Buttons: `Delete`, `Cancel`. |
| all | `Delete all <X> captures? This frees <size> and cannot be undone. Appointments, tasks and reminders found in them are kept.` Buttons: `Delete All`, `Cancel`. |
| shortening retention | `Setting the retention to <N> days removes <X> captures now (<size>). Appointments, tasks and reminders found in them are kept.` Buttons: `Change`, `Cancel`. |

When nothing would be deleted the dialog says `No captures match.` and only offers `OK`.

## One-time messages

- A damaged database was set aside: a dialog `Memorri could not read its capture database and started a new one. The old file was kept as <name> in the Memorri folder.` with `OK`.
- A database from a newer version: `This capture database was created by a newer version of Memorri and was left untouched. Update Memorri to use it.` Capture is disabled until then.

## Settings keys

`memorri.storage.modelLongEdge`, `memorri.storage.retention`, `memorri.retention.lastRun` (see the data model).

## Debug-only launch argument

`--simulate-free-bytes <n>` makes the free-space check report `n` bytes. Compiled into Debug builds only; used by the quickstart to test the 1 GB refusal.

## Log contract (for the quickstart)

Subsystem `com.aletc1.memorri`, category `capture`: `capture finished status=<complete|partial|failed> displays=<n> images=<n> ms=<n>`, plus `capture refused reason=<text>`; category `storage`: `retention removed=<n>`, `cleanup removed=<n>`, `reconcile staging=<n> orphans=<n> missing=<n>`.
