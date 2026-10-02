# 25. Reprocessing trials are stored apart and applied per sighting

- Status: Accepted
- Date: 2026-10-02
- Related: spec 008 (`specs/008-reprocessing/`), ADR 0003, ADR 0020, ADR 0022

## Context and problem
The user wants to read stored captures again with another model or prompt, see what would change, and apply only chosen changes, with an audit trail and undo. Today a re-read (`reread` job) replaces a capture's findings and sightings at once, and nothing can be undone. Model runs and findings are read back by later analyses (reuse), so a trial that wrote there would leak into live results.

## Options considered
1. Run the trial through the live path into a copy of the database.
2. Store the trial's findings in their own tables, compare them with the live items by a dry-run of the matcher, and apply selected differences as sighting-level changes in one operation.
3. Run the live path and offer an undo of the whole re-read.

## Decision
Option 2.
- `trials`, `trial_images` (state and the model run's numbers per capture) and `trial_findings` hold proposals; the live `findings`, `model_runs`, `image_analysis` and items are never written by a trial. A `trial` job kind (priority 1, a `trial_id` column on `analysis_jobs`) reads the capture with the trial's model, reusing the stored OCR text, and stops after the pipeline.
- The comparison runs the reconciler's plan on the proposal findings (a dry run, no writes) and classifies each step against the item it would join: new, changed fields, unchanged; items of the capture that no step joins are `not found`. Locks, approvals and dismissals mark a difference protected.
- Applying a difference adds the proposal's sighting (and observations) to its target item or to a new item and removes the capture's old sighting of that item, through the same recompute and review rules, inside one `apply_trial` operation that stores a before-image of every touched sighting and observation so Undo restores them. The `reconcile_ops.kind` check is rebuilt in a migration, as for `approve`.
- The audit trail is the operation log (`apply_trial` operations with the trial's model and prompt version in `detail`) plus the trials list.

## Consequences
- Easier: nothing a trial does can damage the library; apply is exact and reversible; the same recompute keeps locks and the Inbox rules in force.
- Harder: a second path attaches sightings from stored proposals (kept small by reusing the reconciler's attach step); trial tables add disk, freed by deleting a trial.
- Revisit: comparing more than two trials; automatic apply of unprotected differences.
