# Research: evidence, inline editing and the Inbox

Decisions for [plan.md](plan.md). Each has a decision, the reason and what else was considered.

## R1. When cut-outs are made

- **Decision**: in the analyse job right after `reconcile(imageID:)`, `EvidenceWriter.write(imageID:)` cuts one image per sighting of that picture from the full-size picture already on disk. Sightings without evidence and with their picture still stored (made before this spec) are backfilled once when their item is opened, and by a background pass at launch limited to 200 per run.
- **Rationale**: clarification 2 (saved when analysed). The full picture is decoded once per capture by OCR anyway; the writer reuses `FullPictureProviding`. Failures are logged and never fail the job; a missing cut-out is shown as such.
- **Alternatives**: cutting on demand (rejected in clarification 2); cutting inside the reconcile transaction (file I/O in a write transaction).

## R2. Geometry

- **Decision**: the region is the union of the cited lines' boxes (full-resolution pixels, top-left origin, as stored in `ocr_lines`), grown by a margin of 24 px or 15% of the union's height, whichever is larger, clamped to the picture. If wider than 1600 px it is scaled down to 1600 px wide. Lines cited that are not in `ocr_lines` are ignored; none left means "no cut-out: no lines cited". The region is stored with the evidence row so the whole-capture view can outline it and the lines.
- **Rationale**: SC-001 (every cited line inside, little else); calendar blocks are small, month views are wide.
- **Alternatives**: one cut-out per line (many tiny images for multi-line findings); a fixed-size box (cuts long titles).

## R3. Storage and lifetime

- **Decision**: files `evidence/YYYY-MM/<evidence id>.heic` (quality 0.7) under the app root; table `evidence` with `item_id` (cascade with the item), `sighting_id` (set null when the sighting goes), and copies of `image_id`, capture time, display name, sighting title, region and file size. Removal: with the item (cascade plus file removal in the sweep and wherever items are deleted), with the picture's earlier evidence on reanalysis, and all of it on "Delete everything" (`CleanupService.delete(olderThanDays: nil)`). Retention (`olderThanDays: N`) and per-capture deletes keep it. `StorageStats` reports evidence bytes separately. Orphan files (no row) are removed by `CaptureFileStore.reconcile` at launch.
- **Rationale**: clarification 4. Copies of the sighting's details keep the card meaningful after the sighting is gone.
- **Alternatives**: blobs in SQLite (bloats the database and its backups of the WAL); keeping the evidence on the sighting row (sightings cascade with their capture).

## R4. Evidence follows its sighting

- **Decision**: wherever sightings move between items (`ItemMerge.move`, split, undo, reconcile apply), `evidence.item_id` is updated for those sightings in the same transaction. Evidence whose sighting is gone keeps the item it last belonged to.
- **Rationale**: merge, split and undo must leave the detail views consistent (SC-006 of 005 still holds).

## R5. Review state

- **Decision**: `ReviewRules.evaluate(item, chosen observations, open possible duplicates, approval)` returns reasons from: `low-confidence` (confidence < 0.75), `guessed-start`, `guessed-end`, `guessed-due` (the chosen observation of that field is `inferred` and the field is not locked), `possible-duplicate` (an open row), `changed-after-approval` (any of title, start, end, all-day, due differs from the snapshot taken at approval). `needs_review = !reasons.isEmpty && status == active`. An item with an approval snapshot is judged only on `changed-after-approval`: the approval covers the doubts that were there, so a later sighting of the same thing does not bring it back (FR-012). Merging two approved items re-takes the snapshot of the joined item; a merge with an unapproved one clears it. Stored on `items` by `ItemRecompute` and recomputed on approve, edit, unlock, merge, split, mark different, undo and after `possible_duplicates` changes.
- **Rationale**: FR-010 to FR-015 and clarifications 1 and 3. Stored columns make the count and the Inbox one indexed query (SC-007) and let the menu observe it.
- **Alternatives**: computing on read (needs every item's observations to count the Inbox).

## R6. Approval

- **Decision**: `ItemOperations.approve(itemID)` sets `approved_at` and `approved_values_json` (the resolved title, start, end, all-day, due) and records an `approve` op whose before-state holds the previous approval. An edit approves in the same transaction (FR-014). Undo restores the previous approval with the rest of `ItemState` (two optional fields added, decoded as absent for older ops). A merged item keeps the survivor's approval only if both were approved; otherwise it is cleared (edge case). A split-off item starts unapproved. Implicit approval (no reasons, never approved) is shown as "Approved" without a stored snapshot.
- **Rationale**: one rule for "approved" that spec 009 can read: `needs_review = 0 AND status = 'active'`.

## R7. Inline editing

- **Decision**: one editor per field type in the detail view (text, date-time in the item's zone, all-day toggle, people as comma-separated names, multi-line notes). Each confirmed edit calls `ItemOperations.edit`; validation is in the core (`ItemOperations.isValid` plus new rules: start not after end against the other resolved value, non-empty title, people trimmed and de-duplicated). Clearing a value is an edit to `null` (locked empty).
- **Rationale**: FR-006 to FR-008; validation testable in `swift test`.

## R8. Inbox placement and kinds

- **Decision**: the Inbox is a scope of the Items window (`Items · Inbox (N)` at the top of the list) with the same context filter; the menu's existing `Inbox` entry opens the window on that scope and shows the count. Kind filter: All, Appointments, Tasks (task and deadline), Reminders. The placeholder Inbox window of spec 001 is removed.
- **Rationale**: one window, one detail view with the evidence next to approve and dismiss (SC-004).
- **Alternatives**: a separate Inbox window (two detail views to keep in step).

## R9. Detail size

- **Decision**: 5 newest sightings with cut-outs, then `Show all N sightings` (clarification 5); cut-outs are loaded asynchronously and cached in memory per window (NSCache, 100 images).
