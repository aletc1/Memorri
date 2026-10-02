feat(hardening): cancellation detection, backup and restore, notifications, login item, diagnostics and an app icon (spec 010)

## What
- **Possibly cancelled.** When two later captures of the same calendar dates (week or day views, same context) leave out a meeting, the item goes to the Inbox as `Possibly cancelled`, with when it was last seen and which captures missed it. `Cancelled` dismisses it (sync removes its entry); `Still happening` approves it and stays quiet until it is seen again. Nothing is ever dismissed, changed or unsynced without your decision, and re-reads, reanalysis and trials cannot raise a suspicion.
- **Export, backup and restore** (Settings > Storage). Export every item to one JSON file. Back up the library to a folder (with or without the capture pictures, sizes shown first, progress and cancel, no partial result). Restore validates the backup, then finishes at the next start: the library it replaces is kept as a safety copy, and any failure puts everything back. Calendar sync waits for a preview after a restore.
- **Notifications.** One quiet notice such as `3 new items, 1 needs review` after a burst of captures; none while the Items window is in front; a switch in Settings (on by default); a click opens the Inbox.
- **Open Memorri at login**, following the system's own state.
- **Diagnostics** (Settings > Diagnostics): versions, permissions, queue, sync, storage and sanitised log lines, saved as text or JSON. It never holds item titles, places, people, notes, text read from the screen, window titles or pictures.
- **An app icon**: the brain on a rounded blue square, drawn by `scripts/make-app-icon.swift`.

## Why
The library holds weeks of captures that cannot be taken again, a calendar full of meetings that no longer exist is worse than none, and a background tool needs to say when something is waiting and what it is doing.

## Design
Coverage is measured in absolute instants from OCR headers, the visible windows and the time axis, and is silent when unsure; absences are written only by first analyses; the flag is a review reason computed from them. Restore is staged and swapped before the database opens (ADR 0027). Migration v12 adds `calendar_coverage`, `cancel_absences`, `items.cancel_cleared_at` and widens the operation log by `still_happening`.

Spec: `specs/010-hardening/`. ADR: 0027.

## Verification
- `swift test --package-path Packages/MemorriCore`: all pass, with new suites for the coverage reader, review rule, detector (including scored sequences: all cancellations found, no false flags from scrolled-out, glitched, context-less or non-calendar captures), decisions and undo, exporter, backup, restore (rollback at every step of the swap), notifier, login item, diagnostics (planted strings) and scale (10,000 items checked in under 100 ms).
- Run on the author's real library: see below (to be completed).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
