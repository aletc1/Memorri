# Data model: sync (spec 009)

Migration v11.

- `sync_links(item_id TEXT PK REFERENCES items ON DELETE CASCADE, kind CHECK in ('event','reminder'), ek_id TEXT NOT NULL, container_id TEXT NOT NULL, hash TEXT NOT NULL, hash_version INTEGER NOT NULL, fields_json TEXT NOT NULL, state CHECK in ('synced','completed','removed_by_user','removed','failed'), failure TEXT, synced_at DATETIME NOT NULL, created_at DATETIME NOT NULL)`; index on `ek_id`. `container_id` is the calendar or list the entry was written to.
- `sync_runs(id TEXT PK, started_at, finished_at, preview INTEGER, created, updated, removed, adopted, skipped, failed, detail_json)`; the last 20 are kept.
- Settings (UserDefaults through `SettingsStore`): `sync.enabled`, `sync.calendarID`, `sync.listID`, `sync.firstSyncConfirmed`.

Rules: a link exists only for entries Memorri created; deleting an item removes its link row (the entry is removed first by the planner when the item was dismissed or merged); `fields_json` holds the rendered fields of the last sync so an outside edit can be told from Memorri's own change.
