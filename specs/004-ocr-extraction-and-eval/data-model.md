# Data Model: Read captures and find appointments and tasks

Migration `"v3"` adds the tables below to the database from specs 002 and 003 and one column to `model_runs`. Style and rules follow [spec 003's data model](../003-ollama-connector/data-model.md). **Every table that belongs to one picture references `capture_images(id)` with `ON DELETE CASCADE`**, so deleting a capture in any kind of cleanup removes its text lines, window titles, tags, findings, analysis and context assignment with no new code (spec 002, ADR 0010). Only `contexts` and `context_hints` belong to the user, not to a picture.

## Tables

### contexts and context_hints

| Column | Type | Rules |
|---|---|---|
| `contexts.id` | TEXT, primary key | UUID string. |
| `contexts.name` | TEXT, not null | Shown to the user; unique ignoring case (unique index on `lower(name)`). |
| `contexts.timezone` | TEXT, nullable | IANA identifier; null means the Mac's zone. Validated in code with `TimeZone(identifier:)`. |
| `contexts.created_at`, `updated_at` | DATETIME, not null | |
| `context_hints.id` | TEXT, primary key | |
| `context_hints.context_id` | TEXT, not null | References `contexts` with `ON DELETE CASCADE`. |
| `context_hints.kind` | TEXT, not null | `window_title`, `app`, `domain` or `keyword` (CHECK). |
| `context_hints.value` | TEXT, not null | Matched case-insensitively; leading and trailing spaces trimmed; at least 2 characters. |

Index `context_hints(context_id)`.

### capture_windows

One row per window visible on a display at capture time (up to 20 per picture, largest visible area first). Stored with the pictures in the same transaction.

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | |
| `image_id` | TEXT, not null | `capture_images` with `ON DELETE CASCADE`. |
| `z` | INTEGER, not null | 0 is the largest visible area. |
| `app_name` | TEXT, nullable | |
| `bundle_id` | TEXT, nullable | |
| `title` | TEXT, nullable | Can be blank when the system does not give one. |
| `x`, `y`, `width`, `height` | INTEGER, not null | Frame in the picture's pixel space, top-left origin, clipped to the picture. |

Index `capture_windows(image_id)`.

### ocr_reads and ocr_lines

| Column | Type | Rules |
|---|---|---|
| `ocr_reads.image_id` | TEXT, primary key | `capture_images` with `ON DELETE CASCADE`. A row means "read", even with zero lines. |
| `ocr_reads.read_at` | DATETIME, not null | |
| `ocr_reads.line_count` | INTEGER, not null | |
| `ocr_reads.recogniser` | TEXT, not null | For example `vision-accurate-corrected-r<revision>`; changes when the settings of the recogniser change. |
| `ocr_reads.duration_ms` | INTEGER, not null | |
| `ocr_lines.image_id` | TEXT, not null | `capture_images` with `ON DELETE CASCADE`. |
| `ocr_lines.n` | INTEGER, not null | 1 to `line_count`, reading order. Primary key is `(image_id, n)`, so reading twice cannot duplicate lines. |
| `ocr_lines.text` | TEXT, not null | |
| `ocr_lines.x`, `y`, `width`, `height` | INTEGER, not null | Pixels of the full-resolution picture, top-left origin. |
| `ocr_lines.confidence` | REAL, not null | 0 to 1. |

### image_analysis

One row per analysed picture (the current analysis). No row means not analysed; the state shown in Settings also uses the job (waiting, running, failed with its reason).

| Column | Type | Rules |
|---|---|---|
| `image_id` | TEXT, primary key | `capture_images` with `ON DELETE CASCADE`. |
| `screen_kind` | TEXT, not null | `calendar_month`, `calendar_week`, `calendar_day`, `email`, `chat`, `document`, `other` (CHECK). |
| `kind_confidence` | REAL, not null | |
| `classify_version`, `prompt_version`, `schema_version` | TEXT, not null | `classify-v1`, `extract-<kind>-v1`, `schema-<kind>-v1`. |
| `model` | TEXT, not null | |
| `picture_long_edge` | INTEGER, not null | Longer side of the copy sent. |
| `timezone` | TEXT, not null | IANA identifier used to resolve this picture. |
| `timezone_source` | TEXT, not null | `context`, `mac`, `invalid-context-zone` (CHECK). |
| `finding_count` | INTEGER, not null | |
| `line_cap_applied` | INTEGER, not null, default 0 | 1 when the line list sent to the model was capped. |
| `discarded_json` | TEXT, not null, default `[]` | `[{title, reason, cited_lines}]` for findings dropped for invalid citations. |
| `extract_run_id` | TEXT, nullable | The `model_runs` row of the extraction call. |
| `analysed_at` | DATETIME, not null | |

The classification is saved as soon as its call succeeds (partial row with `finding_count` 0 and `extract_run_id` null is not allowed; instead the step result is kept as a `classify` model run and recomputed from it, see Job steps below).

### image_context

| Column | Type | Rules |
|---|---|---|
| `image_id` | TEXT, primary key | `capture_images` with `ON DELETE CASCADE`. |
| `context_id` | TEXT, nullable | `contexts` with `ON DELETE SET NULL` (a deleted context leaves the picture unassigned). |
| `source` | TEXT, not null | `auto`, `user` or `none` (CHECK). |
| `score` | REAL, not null | 0 for `none` and `user`. |
| `matched_json` | TEXT, not null, default `[]` | `[{hintKind, value, points}]`. |
| `runner_up_json` | TEXT, nullable | `{contextId, score}` or `{tie: true, contextIds: [...]}`. |
| `decided_at` | DATETIME, not null | |

Rule: a row with `source = user` is never changed by analysis.

### capture_tags

| Column | Type | Rules |
|---|---|---|
| `image_id` | TEXT, not null | `capture_images` with `ON DELETE CASCADE`. |
| `key` | TEXT, not null | `display_size`, `display_scale`, `window_app`, `window_title_keywords`, `remote_client`, `language`, `clock_style`, `date_order`, `account`, `domain`, `timezone_label`, `application`, `platform_look`, `remote_session`, `theme`, `calendar_name` (CHECK). Adding a key needs a migration that widens the CHECK, which SQLite cannot do in place, so the list is also validated in code and this CHECK is omitted: **no CHECK on `key`**. |
| `value` | TEXT, not null | |
| `confidence` | REAL, not null | 1 for values read by code from the capture. |
| `source` | TEXT, not null | `code`, `window`, `visual`, or `line:<n>`. |
| | | Primary key `(image_id, key, value)`. |

### findings

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | |
| `image_id` | TEXT, not null | `capture_images` with `ON DELETE CASCADE`. |
| `run_id` | TEXT, nullable | The extraction `model_runs` row. |
| `kind` | TEXT, not null | `appointment`, `task`, `reminder`, `deadline` (CHECK). |
| `title` | TEXT, not null | |
| `all_day` | INTEGER, not null, default 0 | |
| `start_at`, `end_at`, `due_at`, `remind_at` | DATETIME, nullable | UTC instants; for all-day the local midnight. |
| `timezone` | TEXT, not null | IANA identifier used (same as the picture's analysis). |
| `people_json` | TEXT, not null, default `[]` | |
| `place`, `notes` | TEXT, nullable | |
| `cited_lines_json` | TEXT, not null | Sorted distinct line numbers; at least one, all existing in the picture (checked before storing). |
| `confidence` | REAL, not null | Lowest cited-line confidence; at most 0.5 when any field is inferred. |
| `provenance_json` | TEXT, not null | `{field: {origin: "read"|"inferred", rule: "<id>", reason?: "block-height"|"default-60"|"date-order"}}` for every set field. |
| `unresolved_json` | TEXT, not null, default `{}` | `{field: "text as written"}` for values that could not be resolved; the column stays null. |
| `tags_json` | TEXT, not null | Copy of the picture's tags at this run. |
| `created_at` | DATETIME, not null | |

Indexes `findings(image_id)`, `findings(start_at)`.

### model_runs (change)

`ALTER TABLE model_runs ADD COLUMN step TEXT NOT NULL DEFAULT 'test'`; values `test`, `classify`, `extract`. The prompt and schema versions are those of the step. Existing rows read as `test`. A `classify` run's raw answer is how a retry resumes without calling the model again (see Job steps).

## Job steps (how a retry resumes)

| Step | Stored result | Skipped on retry when |
|---|---|---|
| read | `ocr_reads` and `ocr_lines` in one transaction | `ocr_reads` row exists |
| classify | a successful `model_runs` row with `step = classify` (raw answer kept) | such a run exists for this picture with the current `classify_version` |
| extract | parsed in memory, then resolved and stored together with its run in one transaction | never skipped: the extraction call is the last model step; a failure repeats only this step |
| resolve and store | `image_analysis`, `findings`, `capture_tags`, `image_context` in one transaction | never partly written |

A forced reanalysis (`kind = analyse-force`) ignores the stored read and classify results and replaces all four.

## Job kinds and states

`analysis_jobs.kind` gains `analyse` (automatic and backlog) and `analyse-force` (Reanalyse). States and retries are those of spec 003 (3 attempts, 10 s then 60 s; holds without using attempts when the server or model is unavailable). A job whose picture is gone fails at once with `picture no longer stored`.

## Settings (UserDefaults)

| Key | Type | Rules |
|---|---|---|
| `memorri.analysis.auto` | Bool | Default true. |
| `memorri.storage.modelLongEdge` (existing, spec 002) | Int | Default becomes the value chosen by the size study (ADR 0017); an explicit user value is kept. |

## In-memory types

- **RecognisedLine**: `n`, `text`, pixel box, confidence.
- **ScreenKind**: the seven kinds.
- **ClassificationResult**: kind, confidence, visual tag values.
- **FindingDraft**: what the model returned (literal texts, cited lines) before checking and resolving.
- **AnalysisResult**: kind, tags, findings with provenance, discards, context decision, runs, timezone used. What `AnalysisPipeline` returns and what the store saves.
- **GoldenCase**, **EvalReport**: see [contracts/eval-cli.md](contracts/eval-cli.md).
