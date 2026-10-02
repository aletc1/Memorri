# Data model: window-aware analysis

Migration `"v8"`. Style as in [spec 006's data model](../006-items-ui-evidence/data-model.md).

## window_readings (new)

| Column | Type | Notes |
|---|---|---|
| `image_id` | TEXT, not null, references `capture_images(id)` ON DELETE CASCADE | |
| `window_key` | TEXT, not null | `w<stack index>`, or `all` for a capture read as one window. |
| `app_name` | TEXT, null | Copy of the capture's window. |
| `title` | TEXT, null | Copy; never logged. |
| `frame_json` | TEXT, not null | `{x, y, width, height}` in picture pixels. |
| `visible_json` | TEXT, not null | Visible rectangles (R1). |
| `visible_share` | DOUBLE, not null | Visible area over picture area. |
| `relevant` | INTEGER, not null | From the windows call. |
| `kind` | TEXT, null | `ScreenKind` value when relevant. |
| `confidence` | DOUBLE, not null | |
| `remote` | INTEGER, not null, default 0 | A remote-desktop window (clock search, R4). |
| `run_id` | TEXT, null | The `windows` model run. |
| `prompt_version` | TEXT, not null | |
| `created_at` | DATETIME, not null | |

Primary key `(image_id, window_key)`. Replaced as a whole when a picture is analysed again.

## findings (edit)

| Column | Type | Notes |
|---|---|---|
| `window_key` | TEXT, null | Null for analyses made before v8. |

## image_analysis (edit)

| Column | Type | Notes |
|---|---|---|
| `reference_at` | DATETIME, null | The reference instant used for relative dates. |
| `reference_source` | TEXT, null | `window-clock`, `screen-clock`, `capture`, `capture-far-clock`. |
| `windows_read` | INTEGER, not null, default 1 | How many windows were read. |

## sightings (edit) and evidence (edit)

| Column | Type | Notes |
|---|---|---|
| `window_app` | TEXT, null | Copied from the finding's window; null before v8 or without a stack. |
| `window_title` | TEXT, null | Same. Removed by "Delete everything" with the evidence rows; kept with the item otherwise (clarification 4). |

## analysis_jobs (edit)

| Column | Type | Notes |
|---|---|---|
| `priority` | INTEGER, not null, default 0 | 0 new captures and user requests, 1 library re-read. Index `(state, priority, created_at)` replaces `(state, created_at)`. |

Job kinds gain `reread` (stored text reused, model steps redone).

## Provenance reasons (no schema change)

New `FieldProvenance.reason` values, all with origin `inferred` (so ReviewRules flags "Guessed time"): `month-assumed` (shipped in the stop-gap), `month-conflict`, `reference-assumed`.

## Settings

`library-reread-version`: the windows prompt version the library was last queued for; the one-off enqueue runs when it is lower than the current one.

## Rules

- A finding's cited lines must belong to its window; others are discarded (`outside the window`).
- `same-picture-different` applies to findings with the same `window_key` only.
- Evidence regions are clamped to the window's frame.
