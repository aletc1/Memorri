# Data model: search (spec 007)

All tables are derived and can be dropped and rebuilt (R8). Migration `v9`.

## search_items (FTS5)
`CREATE VIRTUAL TABLE search_items USING fts5(item_id UNINDEXED, title, aliases, notes, place, people, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4')`

One row per item whose `status` is `active` or `dismissed`; none for `merged`. Columns: title; aliases (the titles in `item_aliases` other than the current one, space-joined); notes; place; people (the names in `people_json`, space-joined).

Triggers (all delete the item's row first, then insert when the item is not merged):
- `items` AFTER INSERT; AFTER UPDATE OF title, notes, place, people_json, status; AFTER DELETE (delete only).
- `item_aliases` AFTER INSERT, UPDATE, DELETE (rebuild the row of `item_id`).

## search_captures (FTS5)
`CREATE VIRTUAL TABLE search_captures USING fts5(image_id UNINDEXED, body, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4')`

One row per capture with read text: `body` = its lines in reading order, newline-joined. Written by `OCRStore.save` in its transaction (delete the old row, insert the new). Trigger: `ocr_reads` AFTER DELETE removes the row of `old.image_id` (reached by the cascade from `capture_images`, which retention and Delete everything use).

## search_meta
`search_meta(key TEXT PRIMARY KEY, value TEXT)`: `index_version` (integer text). A new library has none, so the first launch builds the index.

## Result types (core, not stored)
- `SearchQuery`: `words`, `phrases`, `excluded`, `kinds` (appointments, tasks, reminders, captures), `context` (any, none, one), `dates` (optional closed range), `includeDismissed`.
- `ItemHit`: item id, title, kind, date, context id, status, review flag, `matchedIn` (title, alias, notes, place, people), marked title and marked snippet.
- `CaptureHit`: image id, captured at, display name, `window` (application, title), up to three `LineHit` (line number, text, marked ranges).
- `SearchState`: `ready`, `preparing(done:total:)`.

## Rules
- A merged item never has a row; undoing a merge sets the status back and the trigger adds the row.
- A capture with no text has no row.
- Rebuild = delete both tables' rows, insert from `items`, `item_aliases`, `ocr_lines`; the result equals the trigger-kept content (SC-005).
