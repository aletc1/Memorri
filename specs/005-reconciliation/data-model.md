# Data model: reconciliation

Migration `"v5"` adds the tables below and two columns to `image_analysis`. Style follows [spec 004's data model](../004-ocr-extraction-and-eval/data-model.md): text ids (UUID strings), dates as GRDB datetimes in UTC, JSON in `_json` text columns. Only `sightings` belongs to a picture (cascade from `capture_images`); everything else belongs to the user's item list and is cleaned by `ItemStore.sweep()` (research R11).

## image_analysis (edit)

| Column | Type | Notes |
|---|---|---|
| `reconciled_at` | DATETIME, null | Set by `Reconciler.apply`. Null for pictures analysed before v5 (clarification 4) and while reconciliation has not run. |
| `reconcile_error` | TEXT, null | Short reason when the step failed; cleared on success. |

## items

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT, primary key | |
| `kind` | TEXT, not null | `appointment`, `task`, `reminder`, `deadline` (the finding kinds). |
| `family` | TEXT, not null | `event` for appointments, `todo` for the rest. Candidates match within a family. |
| `status` | TEXT, not null | `active`, `dismissed`, `merged`. |
| `merged_into` | TEXT, null, references `items(id)` | Set when `status = merged`. |
| `context_id` | TEXT, null, references `contexts(id)` ON DELETE SET NULL | The sightings' context. |
| `title` | TEXT, not null | Resolved. |
| `all_day` | INTEGER, not null, default 0 | Resolved. |
| `start_at`, `end_at`, `due_at`, `remind_at` | DATETIME, null | Resolved. |
| `timezone` | TEXT, not null | From the chosen time observation. |
| `day_key` | TEXT, null | `YYYY-MM-DD` of the start (event) or due (todo) in `timezone`; null for undated todos. Candidate index. |
| `people_json` | TEXT, not null, default `[]` | Resolved. |
| `place`, `notes` | TEXT, null | Resolved. |
| `confidence` | DOUBLE, not null | Highest sighting confidence. |
| `user_touched` | INTEGER, not null, default 0 | Set by any edit, merge, split or restore. Keeps the item when its sightings go. |
| `first_seen`, `last_seen` | DATETIME, not null | Capture times of the earliest and latest sighting. |
| `created_at`, `updated_at` | DATETIME, not null | |

Indexes: `(context_id, family, day_key)`, `(status)`.

States: `active ↔ dismissed` (dismiss, restore); `active → merged` (merge; undo returns it to its previous status). A `merged` item has no sightings and is never a candidate.

## sightings

One finding attached to one item.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT, primary key | |
| `item_id` | TEXT, not null, references `items(id)` ON DELETE CASCADE | |
| `image_id` | TEXT, not null, references `capture_images(id)` ON DELETE CASCADE | |
| `finding_id` | TEXT, not null | The finding's id in that analysis run (findings are replaced on reanalysis; this is for display only). |
| `captured_at` | DATETIME, not null | Recency order. |
| `title` | TEXT, not null | As found. |
| `cited_lines_json` | TEXT, not null | Evidence (spec 006 crops from these). |
| `confidence` | DOUBLE, not null | |
| `decision_json` | TEXT, not null | `{rule, text, time, cosine?, rerank?, candidate?}`, FR-019. |
| `created_at` | DATETIME, not null | |

Indexes: `(item_id)`, `(image_id)`.

## observations

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT, primary key | |
| `item_id` | TEXT, not null, references `items(id)` ON DELETE CASCADE | |
| `sighting_id` | TEXT, null, references `sightings(id)` ON DELETE CASCADE | Null for user observations. |
| `field` | TEXT, not null | `title`, `start`, `end`, `all_day`, `due`, `remind`, `people`, `place`, `notes`. |
| `value_json` | TEXT, not null | |
| `source` | TEXT, not null | `read`, `inferred`, `user`. From the finding's provenance for dates; title, people, place and notes are `read`. |
| `confidence` | DOUBLE, not null | 1 for user. |
| `observed_at` | DATETIME, not null | The capture time, or the edit time for user. |

Index: `(item_id, field)`.

## field_locks

| Column | Type | Notes |
|---|---|---|
| `item_id` | TEXT, references `items(id)` ON DELETE CASCADE | Primary key with `field`. |
| `field` | TEXT | |
| `observation_id` | TEXT, not null, references `observations(id)` | The user value. |
| `locked_at` | DATETIME, not null | |

## item_aliases

| Column | Type | Notes |
|---|---|---|
| `item_id` | TEXT, references `items(id)` ON DELETE CASCADE | Primary key with `normalised`. |
| `normalised` | TEXT | `TitleNormaliser` output; used in matching. |
| `title` | TEXT, not null | One spelling as seen. |

The resolved title's normalised form is always an alias too.

## keep_apart

| Column | Type | Notes |
|---|---|---|
| `item_a`, `item_b` | TEXT, references `items(id)` ON DELETE CASCADE | Primary key; stored with `item_a < item_b`. |
| `op_id` | TEXT, not null | The split or undo that made it. |

## possible_duplicates

| Column | Type | Notes |
|---|---|---|
| `item_a`, `item_b` | TEXT, references `items(id)` ON DELETE CASCADE | Primary key, ordered. |
| `scores_json` | TEXT, not null | Why the pair was uncertain. |
| `created_at` | DATETIME, not null | |

A row goes when the user merges the pair or marks it different (which also writes `keep_apart`).

## reconcile_ops

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT, primary key | |
| `kind` | TEXT, not null | `auto_merge`, `merge`, `split`, `dismiss`, `restore`, `edit`, `unlock`, `context`, `different`, `undo`. One `auto_merge` op per applied plan (a capture), listing every sighting that joined an item that already had sightings from another picture; none when nothing joined. |
| `by_user` | INTEGER, not null | 0 for `auto_merge` and reconciliation after a context change made by code, 1 otherwise. `Undo last` uses the newest `by_user` op. |
| `item_ids_json` | TEXT, not null | Items touched. |
| `moved_json` | TEXT, not null | `[{sighting, from, to}]`. |
| `before_json` | TEXT, not null | Per touched item: status, `merged_into`, locks, aliases, `user_touched`. |
| `detail_json` | TEXT, not null | Scores for `auto_merge`, the chosen value for a merge with conflicting locks (FR-013), the undone op id for `undo`. |
| `undone_by` | TEXT, null | Op id of the undo. |
| `created_at` | DATETIME, not null | |

Index: `(created_at)`.

## reconcile_op_items

| Column | Type | Notes |
|---|---|---|
| `op_id` | TEXT, references `reconcile_ops(id)` ON DELETE CASCADE | Primary key with `item_id`. |
| `item_id` | TEXT, not null | Not a foreign key: the history outlives a removed item. |

Index: `(item_id)`. Feeds an item's History and the undo dependency check.

## title_embeddings

| Column | Type | Notes |
|---|---|---|
| `normalised` | TEXT | Primary key with `model`. |
| `model` | TEXT | |
| `vector` | BLOB, not null | 1024 little-endian `Float32`. |
| `created_at` | DATETIME, not null | |

A cache; entries not used by any alias are removed by the sweep.

## Rules (summary)

- **Field resolution** (`FieldResolver`, research R9): locked user value; read over inferred; higher confidence (within 0.1 is equal); more complete; more recent. Applied per field after every change.
- **Kind**: the most frequent kind among sightings, ties to the latest; a user edit locks it like a field.
- **Context**: the context of the first sighting; items never move across contexts automatically.
- **Reanalysis**: research R2 and rule 0 of R7 (a finding sticks to the item of this picture's earlier sighting).
- **Context change**: research R12a.
- **Removal**: an item with no sightings is deleted by the sweep unless `user_touched`, locked or `dismissed`.
