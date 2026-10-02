# Data model: reprocessing (spec 008)

Migration v10 (next after v9).

- `trials(id TEXT PK, model, prompt_version, think, state CHECK in (running, finished, cancelled), created_at, finished_at NULL)`. Counts are read from `trial_images`.
- `trial_images(trial_id FK cascade, image_id FK cascade, state CHECK in (waiting, read, skipped, failed), reason NULL, finding_count, duration_ms NULL, PK(trial_id, image_id))`
- `trial_findings` = the columns of `findings` (minus `run_id`) plus `trial_id`, `window_app`, `window_title`; FK cascade on `trials` and on `capture_images`; index `(trial_id, image_id)`. Its id is its own, never a live finding id.
- `analysis_jobs.trial_id TEXT NULL` (kind `trial`); jobs of kind `trial` are left out of the menu's counts.
- `reconcile_ops.kind` check rebuilt to add `apply_trial` (as v6 added `approve`). `detail_json` of such an operation: trial id, model, prompt version, trial start time, captures read, difference ids, created item ids, new sighting ids, the removed sightings with their observations (before-image), and the images touched.

Differences are not stored. `TrialComparison.report` works them out when a comparison opens (and `TrialApplier` again when applying, which is the re-check of FR-010). A difference counts as applied when a sighting of the capture has the proposal's finding id (`sightings.finding_id`).

State: a trial is `running` from its creation (its jobs are queued then), `finished` when no capture waits, `cancelled` when the user stops it; `resume` returns it to `running`. `trial_images`: waiting becomes read, skipped (picture gone) or failed (retry returns it to waiting).
Rules: a trial never writes live tables; deleting a trial cascades only trial tables and keeps the operation log; deleting a capture cascades its `trial_images` and `trial_findings`.
