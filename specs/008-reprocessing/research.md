# Research: reprocessing (spec 008)

## R1. Isolation of trial data
Decision: tables `trials`, `trial_images`, `trial_findings` (ADR 0025). A trial writes nothing to `findings`, `model_runs`, `image_analysis`, `capture_tags`, `window_readings`, items or sightings. Reason: `latestSuccessfulRun` and the classify reuse read `model_runs` image-wide and not by model, so trial rows there would leak into live analyses.

## R2. Reading a capture for a trial
Decision: a `TrialJobRunner` (job kind `trial`, priority 1, new nullable column `analysis_jobs.trial_id`) builds `ModelStepSettings(model: trial.model, think: current, timeout: current)`, reads stored OCR text (`OCRStore`, no re-OCR), builds the `PipelineInput` with no model reuse, calls `AnalysisPipeline.analyse` and stores the result in the trial tables, then stops. Window readings of the trial are kept inside the proposal (finding window key and frame in `trial_findings`). The prompt version is the compiled one (`ExtractionPrompts`); it is recorded on the trial, not chosen (there is no setting for it today).

## R3. Queue and progress
Decision: one queue, jobs run one at a time, new captures (priority 0) always first. Trial jobs are excluded from `hasPendingAnalysis`, the capture overview and the menu counts (they filter by kind already); the trial's own progress comes from `trial_images` counts. After a restart `recoverRunningJobs` returns a running job to waiting; the runner skips a capture already `read` in its trial, so nothing is read twice (SC-007).

## R4. Comparison
Decision: pure `TrialComparison` in core. For each captured image of the trial it runs `Reconciler.plan` on the trial's findings (the plan takes findings and a context instead of reading `image_analysis`; no writes). A step targeting `.existing(item)` whose item fields differ from the proposal is `changed` (field list with current and proposed text); equal is `unchanged`; `.newItem` is `new`; current items of this capture's sightings not targeted are `notFound`. Protected: any changed field locked by the user (`locks`), item approved by the user, or dismissed item. Two trials are compared proposal by proposal (`between`), capture by capture; the current items are not part of that comparison.

## R5. Apply
Decision: `TrialApplier` applies selected differences in one transaction: for `new` a new item with the proposal's sighting; for `changed` a new sighting on the target item replacing the capture's old sighting of it; then `ItemStore.recompute` (locks via `FieldResolver`, review rules). The operation kind `apply_trial` is added; its before-image (old sightings and observations of the touched items for that capture, item ids created) lets Undo restore them by id. Re-check at apply time: the target item must still exist, not be merged, and the field values must still equal the ones compared; otherwise the difference is `skipped(reason)`. Idempotence: a difference whose proposal sighting is already on the item is `applied` and a second apply does nothing.

## R6. Out-of-date count
Decision: `image_analysis.model` and `prompt_version` against the current model setting and `ExtractionPrompts` versions; a pure count query, shown in Settings > Analysis.

## R7. Audit trail
Decision: `reconcile_ops` rows of kind `apply_trial` carry the trial's id, model, prompt version, start time and captures read, so the record outlives the trial; trials are listed while they exist. An item's history already lists operations by item; the new kind gets its words.
