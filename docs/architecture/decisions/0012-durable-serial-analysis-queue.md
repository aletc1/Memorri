# 12. A durable, serial analysis queue in the local database

- Status: Accepted
- Date: 2026-09-30
- Related: spec 003 (FR-012 to FR-016), ADR 0003, ADR 0005, spec 002 ADR 0009

## Context and problem
A 27-billion-parameter vision model takes seconds to minutes per picture and must not run in parallel on a normal Mac. Work for it must survive quitting, crashes and a server that is off, retry when something temporary goes wrong, and show progress. Later specs (extraction, reprocessing) put their jobs in the same place.

## Options considered
1. In-memory queue (`OperationQueue` with one slot): simple, but jobs are lost on quit and retries are ad hoc.
2. A separate job store (file or second database): durable, but a second persistence mechanism to migrate and back up.
3. A table in the existing SQLite database, worked by one long-lived loop.

## Decision
Option 3. Jobs are rows in `analysis_jobs` (migration `v2`). One `AnalysisQueue` actor loop takes the oldest runnable job, so two jobs never run together by construction. `attempts` counts failed attempts only, so a quit during a run costs nothing and the running job returns to `waiting` at start. Temporary failures retry up to 3 attempts with waits of 10 s then 60 s; permanent failures fail at once; an unavailable server or missing model holds the queue without using attempts and is rechecked every 30 s. Pause is one persisted flag. Every attempt writes a `model_runs` row that references its picture with `ON DELETE CASCADE`, so the existing capture cleanup removes runs with their capture. Jobs carry no foreign key to pictures so a job can outlive its picture and fail with a clear reason.

## Consequences
- Adding a job kind means a new `kind` value, a runner and, if needed, a migration; the queue itself does not change.
- Job order is creation order only; priorities would need a column and a new decision.
- The database grows with raw answers; they expire with their captures (7 days by default).
