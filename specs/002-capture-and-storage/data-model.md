# Data Model: Capture every display and keep the captures

Two tables in SQLite (migration "v1"), one folder of files per capture, and two settings. Names follow the draft schema from the original plan, reduced to what this spec needs; later specs add tables (OCR lines, extraction runs, entities) in their own migrations.

## Tables

### capture_events

One capture request that reached the capturing step.

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | UUID string, also the name of the capture's folder. |
| `captured_at` | DATETIME, not null | When the capture started (UTC). Indexed, used by retention and cleanup. |
| `trigger` | TEXT, not null | `menu` or `shortcut` (CHECK constraint). |
| `status` | TEXT, not null | `complete`, `partial` or `failed` (CHECK constraint). |
| `failure_reason` | TEXT, nullable | Short reason when `status` is not `complete`, for example `Not enough free disk space`, `permission denied`, `1 of 3 displays could not be captured`. |
| `display_count` | INTEGER, not null | Displays the capture attempted (distinct displays, mirror sets counted once). |

Rules:
- A failed capture (for example permission refused, no disk space) is recorded as an event with no images (FR-003, FR-007).
- Deleting an event deletes its images (foreign key with `ON DELETE CASCADE`) and its folder (FR-016).

### capture_images

The pictures of one display within one capture.

| Column | Type | Rules |
|---|---|---|
| `id` | TEXT, primary key | UUID string. |
| `event_id` | TEXT, not null | Foreign key to `capture_events.id`, `ON DELETE CASCADE`. Indexed. |
| `display_id` | INTEGER, not null | The system display identifier at capture time (not stable across restarts; informational). |
| `display_name` | TEXT, nullable | Human name of the display when available. |
| `pixel_width`, `pixel_height` | INTEGER, not null | Size of the full-resolution picture in pixels. |
| `scale` | REAL, not null | Backing scale of the display (1.0, 2.0, ...). |
| `full_path` | TEXT, not null | Relative to the data folder, `captures/<yyyy-MM>/<eventID>/<imageID>-full.heic`. |
| `model_path` | TEXT, not null | Relative path of the analysis copy, `...-model.heic`. |
| `model_width`, `model_height` | INTEGER, not null | Size of the analysis copy. Longer side equals the configured size, or the original size when that is smaller (never enlarged). |
| `full_bytes`, `model_bytes` | INTEGER, not null | File sizes at write time. |
| `missing` | INTEGER, not null, default 0 | 1 when a file was found missing at start (FR-014). |

### Migration and versioning

- One migration, `"v1"`, creates both tables, the CHECK constraints and two indexes (`capture_events(captured_at)`, `capture_images(event_id)`).
- The database is opened with foreign keys on. A database with migrations the app does not know is left untouched and reported (`hasBeenSuperseded`). A damaged file is renamed `memorri.sqlite.damaged-<yyyyMMdd-HHmmss>` and never deleted.

## Files

```text
~/Library/Application Support/Memorri/        mode 0700, excluded from backups
├── memorri.sqlite (+ -wal, -shm)
├── captures/
│   └── 2026-09/
│       └── <eventID>/
│           ├── <imageID>-full.heic
│           └── <imageID>-model.heic
└── staging/                                   captures being written; emptied at every start
```

## Lifecycle of a capture (state transitions)

| Step | What exists | If it fails or the app stops here |
|---|---|---|
| 1. Request accepted | nothing | nothing to clean up |
| 2. Free space checked (at least 1 GB) | nothing | event `failed` ("Not enough free disk space"), no pictures |
| 3. Displays captured | images in memory | permission refused: event `failed`, status becomes "not granted", onboarding opens; other failure: event `failed` or `partial` |
| 4. Encoded and written | `staging/<uuid>/` | folder removed; event `failed` |
| 5. Folder moved into `captures/…/<eventID>/` | folder with pictures, no record yet | the start-up sweep removes a folder without a record |
| 6. Records inserted in one transaction | event + images | if the transaction fails the folder is removed |
| 7. Outcome shown | menu line, flash and sound | |

The event row is written only at step 6 (and for failures, in a transaction of its own), so a capture that is still being written is never visible to cleanup and cannot be deleted by it.

## Settings (UserDefaults)

| Key | Type | Rules |
|---|---|---|
| `memorri.storage.modelLongEdge` | Int | 512 to 4096, default 2048. Out of range is rejected and the previous value kept. Applies to later captures only. |
| `memorri.storage.retention` | String | `forever` or the number of days as text (1 to 3650). Default `7`. |
| `memorri.retention.lastRun` | Date | Last automatic retention run, used to run it about once a day. |

## In-memory types

- **LastCaptureResult**: `complete`, `partial(captured: Int, of: Int)` or `failed(reason: String)`, with the time. Shown at the top of the menu; not stored.
- **StorageSummary**: capture count, bytes used by pictures, bytes used by the database files. Computed when the Storage section opens.
- **ScreenRecordingStatus** gains two transitions from the real capture (see the 001 data model): a successful capture sets `granted` from any state, and a capture refused for permission sets `notGranted` from any state. The fresh-process probe keeps running as before.
