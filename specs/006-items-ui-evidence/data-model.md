# Data model: evidence, review and approval

Migration `"v6"`. Style as in [spec 005's data model](../005-reconciliation/data-model.md).

## evidence (new)

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT, primary key | Also the file name. |
| `item_id` | TEXT, not null, references `items(id)` ON DELETE CASCADE | Follows the sighting on merge, split and undo (research R4). |
| `sighting_id` | TEXT, null, references `sightings(id)` ON DELETE SET NULL | Null once the capture is deleted. |
| `image_id` | TEXT, not null | Copy, no foreign key (the picture may be gone). |
| `captured_at` | DATETIME, not null | Copy. |
| `display_name` | TEXT, null | Copy. |
| `title` | TEXT, not null | The sighting's title as found. |
| `cited_lines_json` | TEXT, not null | Line numbers cited. |
| `region_json` | TEXT, not null | `{x, y, width, height}` in full-resolution pixels. |
| `file_path` | TEXT, null | Relative to the app root; null when no lines were cited (`reason` says why). |
| `reason` | TEXT, null | `no-lines`, `picture-missing`, `failed` when there is no file. |
| `bytes` | INTEGER, not null, default 0 | File size, for the storage figures. |
| `created_at` | DATETIME, not null | |

Indexes: `(item_id, captured_at)`, `(image_id)`, unique `(sighting_id)` where not null.

## items (edit)

| Column | Type | Notes |
|---|---|---|
| `needs_review` | INTEGER, not null, default 0 | Set by `ItemRecompute` (research R5); 0 for dismissed and merged items. |
| `review_reasons_json` | TEXT, not null, default `[]` | `low-confidence`, `guessed-start`, `guessed-end`, `guessed-due`, `possible-duplicate`, `changed-after-approval`. |
| `approved_at` | DATETIME, null | Set by approve and by an edit. |
| `approved_values_json` | TEXT, null | Resolved `title`, `start`, `end`, `all_day`, `due` at approval. |

Index: `(needs_review, status)`.

Existing rows: the migration computes `needs_review` for every item with the rules once (in Swift, after the schema change).

## reconcile_ops (edit)

`kind` gains `approve`. `ItemState` gains `approvedAt` and `approvedValues` (optional; older entries decode them as absent).

## Rules

- **Review level**: 0.75, a constant (`ReviewRules.level`).
- **Approved** (what spec 009 reads): `status = 'active' AND needs_review = 0`.
- **Merge**: the survivor's approval stays only when both items were approved; otherwise both approval columns are cleared.
- **Split**: the new item has no approval.
- **Files**: removed when their row is deleted (item removal, reanalysis, "Delete everything"); orphans removed at launch.

## As built

- Migration `"v6"` changes the schema; `"v6-review"` computes `needs_review` and `review_reasons_json` once for existing items (review columns only, nothing else is rebuilt).
- An item with an approval snapshot is judged only on `changed-after-approval` (the approval covers earlier doubts). Merging two approved items takes a new snapshot of the joined item; merging with an unapproved one clears the approval. A possible duplicate whose other item is merged away does not count as open.
- A locked `null` observation means the user cleared the field.
- Migration `"v7"` adds `evidence.geometry` (integer, default 1): the shape of the cut-out (2 = the cited lines in their context). Older ones are made again while their picture is stored.
