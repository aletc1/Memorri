# Data model: reprocessing (spec 008)

Migration v10 (next after v9).

- `trials(id TEXT PK, model, prompt_version, think, state CHECK in (queued, running, finished, cancelled), created_at, finished_at NULL, total_images, read_images, skipped_images, failed_images)`
- `trial_images(trial_id FK cascade, image_id FK cascade, state CHECK in (waiting, read, skipped, failed), reason NULL, finding_count, duration_ms NULL, timezone NULL, reference_at NULL, PK(trial_id, image_id))`
- `trial_findings` = the columns of `findings` plus `trial_id`; FK cascade on `trials`; index `(trial_id, image_id)`. Its id is its own, never a live finding id.
- `analysis_jobs.trial_id TEXT NULL` (kind `trial`).
- `trial_differences(id PK, trial_id FK cascade, image_id, kind CHECK in (new, changed, notFound), item_id NULL, finding_id NULL, fields_json, protected_reason NULL, state CHECK in (open, applied, skipped), skip_reason NULL, applied_op_id NULL)`: written when a comparison is opened, refreshed when the live item or capture changes.
- `reconcile_ops.kind` check rebuilt to add `apply_trial` (as v6 added `approve`); `detail_json` of such an operation: trial id, model, prompt version, difference ids, created item ids, before-image of the touched sightings and observations.

State: trial queued → running → finished (or cancelled; can be resumed to running). `trial_images` waiting → read | skipped (picture gone) | failed (retry → waiting).
Rules: a trial never writes live tables; deleting a trial cascades only trial tables; deleting a capture cascades its `trial_images`/`trial_findings`.
