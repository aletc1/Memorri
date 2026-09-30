# 9. Capture storage: one private folder, one directory per capture, atomic writes

- Status: Proposed
- Date: 2026-09-30
- Related: spec 002, ADR 0003 (SQLite with GRDB), ADR 0004 (per-display capture)

## Context and problem
Spec 002 stores screenshots of work sessions and a record of each. The data is sensitive, can be large, and must never be left half-written by a failure or a crash. Cleanup has to remove a capture completely and cheaply.

## Options considered
1. Pictures inside the SQLite database: one file to manage, but a large database, slow backups of the file and no simple way to delete one capture.
2. Files written in place, records afterwards: simple, but a crash leaves files without records or records without files.
3. Files staged in a temporary directory, renamed into place, then records written in one transaction: two steps, but a crash leaves either nothing or a complete capture, plus a detectable leftover.

## Decision
Option 3. Everything lives in `~/Library/Application Support/Memorri/` (mode 0700, excluded from backups): the SQLite database (`memorri.sqlite`) and `captures/<yyyy-MM>/<eventID>/` with the full-resolution and analysis pictures, both HEIC at a named quality. A capture is written to `staging/<uuid>/`, the directory is renamed into place (atomic on the same volume), then the event and image records are inserted in one transaction. Deleting a capture is removing its rows and its directory. At start, `staging/` is emptied, directories without a record are removed and records without a file are marked missing. Paths in the database are relative to the folder.

## Consequences
- A crash or failure at any step leaves no visible partial capture; a capture in progress is invisible to cleanup.
- One code path deletes captures for retention, age cleanup and delete-all.
- Moving or renaming the data folder does not break the records.
- The start-up sweep has a small cost proportional to the number of captures.
- Pictures are not encrypted by the app; protection is the folder mode, backup exclusion and FileVault.
