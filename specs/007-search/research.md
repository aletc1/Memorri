# Research: search (spec 007)

## R1. Where the index lives
- **Decision**: FTS5 virtual tables in `memorri.sqlite` (migration `v9`), tokenizer `unicode61 remove_diacritics 2`, prefix indexes for 2 to 4 letters.
- **Rationale**: one file, one transaction, so freshness is a property of the write, not of a second process; the constitution already names FTS5; case and accent folding come with the tokenizer, for both the index and the query.
- **Alternatives**: a separate index file (can drift, two writers); Core Spotlight (leaves the app's library and content would leave our control); a LIKE scan (200,000 lines per keystroke is too slow and has no ranking).

## R2. Item documents are kept by triggers
- **Decision**: `search_items(item_id UNINDEXED, title, aliases, notes, place, people)` holds one row per item whose status is not `merged`. Triggers on `items` (insert, update of the searchable columns or status, delete) and on `item_aliases` (insert, update, delete) replace the item's row with one built from the tables by a single SQL expression (`json_each` for people, `group_concat` for aliases). Every trigger deletes the item's row first, so `INSERT OR REPLACE` cannot leave a stale one.
- **Rationale**: items change in many places (reconciler, edits, merge, split, undo, sweep, retention); triggers cover all of them, including future ones, with no call to remember (FR-011, SC-003).
- **Alternatives**: explicit calls in each operation (easy to miss one; a missed one is a silent stale result).

## R3. Capture documents are written with the text
- **Decision**: `search_captures(image_id UNINDEXED, body)` has one row per capture whose text was read, where `body` is its lines in reading order joined by newlines. `OCRStore.save` writes it in the same transaction as the lines (delete, then insert). A trigger on `ocr_reads` delete (reached by the cascade from `capture_images`) removes it, so retention and Delete everything leave nothing.
- **Rationale**: the spec requires all words of a query to match in the capture, not on one line; a per-capture document gives that, and one write per capture avoids rebuilding the document line by line. `ocr_reads` is written before the lines, so an insert trigger cannot see them; the explicit write can.
- **Alternatives**: an index of lines (all words would have to share a line, so "invoice friday" would miss); an external-content index on `ocr_lines` (same line limit).

## R4. Matching lines and the window are found after ranking
- **Decision**: FTS ranks and pages captures (bm25, then newest). For each capture on the page, the core reads its lines (a few hundred rows) and picks up to three that contain the most query words, using the same folding and prefix rule in Swift (`SearchText`), marks the words in them, and names the window by hit-testing the line's centre against the capture's stored `window_readings` (visible parts, front to back).
- **Rationale**: no second index; 20 captures per page bounds the work; the marks need character positions that the index does not give.
- **Alternatives**: `snippet()` on the whole body (cuts across lines, no line numbers for outlining).

## R5. The typed text becomes a match expression in one place
- **Decision**: `SearchQuery.parse(text)` returns words, quoted phrases and excluded words; every term is wrapped in quotes with inner quotes removed, so no input reaches FTS syntax unescaped; the last word gets a prefix star; all terms are joined with `AND`, exclusions with `NOT`. A query with no positive term, or fewer than two letters in all, is "too short" and does not run.
- **Rationale**: FTS5 syntax errors on stray quotes, `-`, `:` and `*`; one tested function makes "never fails" true (FR-002).
- **Alternatives**: catching the SQLite error and falling back (hides bugs, and the fallback is a different search).

## R6. Ranking
- **Decision**: items by `bm25` with weights title 10, aliases 6, notes 2, place 2, people 2, then newest `last_seen`; captures by `bm25` of the body, then newest capture. Items are always listed before captures.
- **Rationale**: simple, explainable (FR-003); title hits should beat a word in notes.
- **Alternatives**: embeddings or the reranker model (out of scope: no model call for search).

## R7. Filters are SQL conditions on joined tables
- **Decision**: kind (`items.kind` with the Items window's families: Tasks include deadlines), context (`items.context_id`, capture `image_context.context_id`; "none" is `IS NULL`), date (item: `start_at` for events, `due_at` then `start_at` for to-dos; capture: `capture_events.captured_at`), status (`dismissed` only with the choice). "Captures" as a kind hides items and, when it is the only kind, the item query is skipped.
- **Rationale**: one place, tested against the same fixtures as the list filters.

## R8. Keeping up, rebuilding, and "preparing"
- **Decision**: `search_meta` holds `index_version`. At launch, `SearchIndex.prepare()` compares it with `SearchIndex.version`; when different, or an integrity probe fails (item count in the index differs from the items that should be there), it rebuilds: items in one transaction, captures in batches of 100 pictures, each batch idempotent; the state is `preparing(done, total)` until the end. Triggers keep new writes correct meanwhile. The same function is the test oracle for SC-005.
- **Rationale**: old libraries have no index; a damaged one must heal without the user; batches keep the writer free for analysis.

## R9. The panel
- **Decision**: a floating `NSPanel` (titled-less, `.nonactivatingPanel` off so it can take keys, `canBecomeKey` true), centred on the display with the pointer, hosting SwiftUI; it closes on Escape and when it loses key status. One global shortcut name `search` (default Control-Option-Command-F) in KeyboardShortcuts, recorded in Settings under the capture one, validated against it (`ShortcutValidator.otherActions`). The menu item calls the same controller.
- **Rationale**: matches the capture feedback pattern; a normal window would pull the user out of the app they are in.

## R10. Opening results
- **Decision**: an item opens the Items window with the scope and filters that show it (dismissed switches the dismissed toggle on) and the item selected. A capture opens a small capture viewer window that shows the picture with the matching lines outlined (the whole-capture view of spec 006, moved into a shared view) or, when the picture is gone, the text lines.
- **Rationale**: items already have a detail; captures have none, and spec 006 already shows a capture with outlined lines.

## R11. The Items window search field
- **Decision**: a field above the list; typing runs the same item search with the window's kind, context and dismissed filters and shows only those items, in rank order; clearing restores the list.
- **Rationale**: FR-010; shares the code, no second matcher.

## R12. What is logged
- **Decision**: category `search`: `search items=<n> captures=<n> ms=<n>`, `search index prepare done=<n> total=<n>`, never text.

**Checked (2026-10-02, task T001)**: through GRDB on the system SQLite (3.54, FTS5 compiled in), `unicode61 remove_diacritics 2` with `prefix = '2 3 4'` finds `Café - Pruebas` by `"cafe" AND "pru"*`, folds `ñ` to `n`, supports `a NOT b` and `bm25()` with column weights, and a trigger that deletes the row before inserting survives `INSERT OR REPLACE`.

## As built (differences from the decisions above)

- **R6**: captures are listed newest first (not by bm25), as the acceptance scenarios say; bm25 ranks items only. Items are ranked by bm25 with the weights above, then newest `last_seen`.
- **R4**: the lines of a capture are read with an SQL filter (the word as a substring, ASCII, any case, plus every line with a non-ASCII character), then matched in Swift; a result's window is the first matching line's frontmost visible window.
- **R8**: the rebuild probe also compares the capture rows with the pictures that have non-blank text, so a missing or left-over row is noticed at launch.
- **R9**: the panel calls `NSApp.activate()` but the app can stay inactive when the shortcut is pressed in another app; the non-activating panel still takes the keys (checked with the shortcut and typing over another app).
- **Names in tests** are generic (a real project name from a screenshot was replaced everywhere before the branch was pushed).

