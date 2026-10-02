# Data model: hardening (spec 010)

## Migration v12
```sql
CREATE TABLE calendar_coverage (
  image_id TEXT NOT NULL REFERENCES capture_images(id) ON DELETE CASCADE,
  window_key TEXT NOT NULL DEFAULT '',          -- '' when the picture was read as one
  context_id TEXT,                              -- the context decision of the capture; NULL = none
  kind TEXT NOT NULL CHECK (kind IN ('calendar_week','calendar_day')),
  spans_json TEXT NOT NULL,                     -- [{"from": epoch seconds, "to": epoch seconds}] one per visible day column
  created_at DATETIME NOT NULL,
  PRIMARY KEY (image_id, window_key));
CREATE INDEX calendar_coverage_context ON calendar_coverage(context_id);

CREATE TABLE cancel_absences (
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  image_id TEXT NOT NULL REFERENCES capture_images(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL,                       -- capture event of the image: two absences count only from different events
  captured_at DATETIME NOT NULL,
  PRIMARY KEY (item_id, image_id));
CREATE INDEX cancel_absences_item ON cancel_absences(item_id, captured_at);

ALTER TABLE items ADD COLUMN cancel_cleared_at DATETIME;   -- `Still happening`: absences count again only after a later sighting
```
Deleting a capture removes its coverage and absences (cascade); a suspicion that depended on it is recomputed by the next `recompute`.

## Types
- `CalendarCoverage { imageID, windowKey, contextID?, kind, spans: [DateInterval] }`.
- `ReviewReason.possiblyCancelled = "possibly-cancelled"` with the words `Possibly cancelled`.
- `ReviewRules.reasons(... cancelAbsences: Int, lastSighting: Date?, clearedAt: Date?)`: adds `.possiblyCancelled` for an active item with at least two absences from distinct events captured after `max(lastSighting, clearedAt)`; applied also to approved items.
- `ReconcileSummary.createdItemIDs: [String]`.
- `BackupManifest { format: Int, schema: String, app: String, created: Date, includesPictures: Bool, files: [{path, size, sha256}] }`.
- `SafetyCopy { name, created, size }`, listed from `safety-copies/`.
- `DiagnosticsInputs` (figures only) and `DiagnosticsReport { text, json }`.

## State transitions
Item: active → flagged (two absences) → cleared by a later sighting (flag removed, absences dropped), or `Cancelled` (dismissed), or `Still happening` (approved, `cancel_cleared_at` set, absences deleted; undo restores both).
Restore: none → staged (`restore-pending/`) → finished at launch (safety copy created, `restore-result.json`) or rolled back.
