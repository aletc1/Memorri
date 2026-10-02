# 27. Cancellations from measured calendar coverage, and restore finished at launch

- Status: Accepted
- Date: 2026-10-02
- Related: spec 010 (`specs/010-hardening/`), ADR 0020 (items), ADR 0021 (review state), ADR 0022 (windows), ADR 0025 (trials), ADR 0026 (sync)

## Context and problem
Two decisions in spec 010 carry risk. (1) A meeting that is missing from a later calendar capture may be cancelled, moved, scrolled out of view or simply not rendered yet; a wrong flag costs the user trust, a wrong silent removal costs them a meeting. (2) Restoring a backup replaces the database while the app holds it open through a connection pool, observers and a running queue.

## Options considered
**Cancellation**
1. Ask the vision model whether each known meeting is still listed.
2. Record, from OCR headers, the visible windows and the time axis, the exact instants a week or day view showed; infer absence only inside them, after two such captures.
3. Day-level coverage only, flag after one capture.

**Restore**
1. Close and reopen the database pool in process.
2. Stage the backup, restart, and swap the files before the database is opened; the replaced library moves aside as a safety copy.
3. Copy files over the live ones.

## Decision
Cancellation: option 2. Coverage is a list of absolute-instant spans per captured week or day view (never month views, whose cells truncate), empty when the dates are guessed, the time axis is unreadable or a column is not visible. Absences are recorded only by the first analysis of a capture and counted per capture event; two absences after the latest sighting add the review reason `Possibly cancelled`. The flag never changes, removes or unsyncs anything; `Cancelled` is `Dismiss`, `Still happening` is `Approve` plus a cleared-at mark.
Restore: option 2. `StorageBootstrap` finishes a staged restore before opening the database; every step is a rename within the volume and a failure moves everything back.

## Consequences
- Easier: the detector is a function of stored rows, tested on synthetic sequences with the eval harness; the restore swap is tested on temporary directories and cannot race the queue.
- Harder: detection starts only for items seen in a view captured after this version; a restore needs a restart; coverage reading depends on OCR of hour labels and headers (silence when unsure).
- Revisit: month views with "+N more" detection, a one-capture mode, in-process restore, scheduled backups.
