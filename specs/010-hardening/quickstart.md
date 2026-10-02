# Quickstart: hardening (spec 010)

1. `swift test --package-path Packages/MemorriCore` (coverage, detector, rules, notifier, backup, restore, diagnostics, login). `memorri-eval reconcile` includes the new calendar sequences with known cancellations (SC-001).
2. Icon: `swift scripts/make-app-icon.swift`, then `xcodegen generate` and build; look at the app in Finder and in System Settings > Privacy & Security.
3. Cancellation (Debug build): `Memorri --ingest-case` a week view with three meetings, then twice a week view of the same dates with two; the third shows `Possibly cancelled` in the Inbox after the second only. `Still happening` clears it; `Cancelled` dismisses it.
4. Notifications: ingest three captures in a minute; one notice with the totals appears; with the Items window in front none does; turn the switch off, none.
5. Backup: `Back up library…` with and without pictures; add and dismiss an item; `Restore from backup…`, restart; the library matches the backup and Settings > Storage lists the safety copy. A file that is not a backup is refused.
6. Diagnostics: `Save report…`, then search the file for a known title, place and OCR word: no match.
7. Login: switch on, check System Settings > General > Login Items lists Memorri; remove it there, reopen Settings: the switch is off.
