# Research: Capture every display and keep the captures

Each item: Decision, Rationale, Alternatives considered. Items marked **Spike** are platform assumptions that the first tasks must prove on this Mac before more code is built on them (lesson from spec 001: see `docs/postmortems/2026-09-29-permission-and-launch-assumptions.md`).

## R1. Capturing a display: ScreenCaptureKit one-shot screenshots

- **Decision**: Get the displays from `SCShareableContent.current`, build a content filter per display with no excluded windows, and capture with `SCScreenshotManager.captureImage(contentFilter:configuration:)`. The configuration hides the cursor (`showsCursor = false`, FR-001) and asks for the display's native pixel size (points times the filter's pixel scale), so the picture is at full resolution.
- **Rationale**: Purpose-built for one-shot captures (ADR 0004), works per display, handles full-screen and Spaces content, and is the API the permission system expects.
- **Alternatives**: `CGDisplayCreateImage` (deprecated, and changes how permission is asked), a stream per display (more moving parts for a single frame).
- **Mirrored displays**: a mirror set is treated as one display. The display list is filtered with `CGDisplayIsInMirrorSet` and `CGDisplayMirrorsDisplay`, keeping one member per set.
- **Spike S1**: with the three displays of this Mac, confirm one image per display at the native pixel size, no cursor, and what the list looks like with mirroring switched on (if a test is practical).
- **S1 outcome (2026-09-30, done)**: `SCShareableContent.current` listed 3 displays in 90 ms, each 3440x1440 points at `pointPixelScale` 1.0; `captureImage` with `width/height = contentRect x pointPixelScale` returned 3440x1440 for each (native size), `showsCursor = false` accepted. All three report `CGDisplayIsInMirrorSet == 0`. Not verified here: a real mirror set and the pointer not showing (both checked in quickstart Scenario 1 and SC-012; mirroring stays untested unless a mirror is set up by hand).

## R2. Telling "permission refused" from other failures

- **Decision**: `CaptureFailure` has three cases: `permissionDenied`, `noDisplays`, `other(String)`. The ScreenCaptureKit adapter maps the error it gets (expected: `SCStreamError.userDeclined`, code -3801, and the equivalent failure from `SCShareableContent`) to `permissionDenied`. `PermissionMonitor.captureDeniedByPermission()` then sets "not granted" and the onboarding window opens. A successful capture calls `captureSucceeded()`, which sets "granted" from any state.
- **Rationale**: Spec 001 proved a running process cannot see permission changes itself. The real capture is the only call that always tells the truth (FR-007, FR-010).
- **Spike S2** (can be run by the assistant with `tccutil`): with the permission granted, run a capture; reset it with `tccutil reset ScreenCapture com.aletc1.memorri` while the app runs; capture again and record the exact error type and code from both `SCShareableContent.current` and `captureImage`. Also check whether a process that has lost the permission still captures from a cached grant (if it does, the failure path needs the probe from 001 as a second signal).
- **S2 outcome (2026-09-30, done; temporary `--spike-capture` loop started through `open -n -W`, `tccutil reset` after 8 s, run twice)**: one second after the reset both `SCShareableContent.current` and `SCScreenshotManager.captureImage` (with a display filter cached before the reset) throw `NSError` domain `com.apple.ScreenCaptureKit.SCStreamErrorDomain`, code **-3801** (message is localized, so match on domain and code, never on text). The process does **not** keep capturing from a cached grant, and it stays denied for the rest of the run (17 s). `CGPreflightScreenCaptureAccess()` keeps returning `true` in the running process throughout, so it must not be used as a signal. Conclusion: a real capture is a reliable, immediate revocation signal inside the running app, and the R2 mapping (`-3801` from either call gives `permissionDenied`) is confirmed. One unexplained observation: in the first run the capture recovered 9 s after the reset without an intended grant (a later probe read `granted`), which may have been a manual action; the second run did not recover. The permission must therefore be re-granted by hand after this spike.

## R3. Picture format and quality

- **Decision**: Both pictures are HEIC, written with ImageIO (`CGImageDestination`, type `public.heic`) at a named quality `StorageQuality.fullResolution = 0.9` and `StorageQuality.analysisCopy = 0.9` (FR-004: small loss, one named level that can be raised). The analysis copy is HEIC too; spec 003 converts to whatever the model accepts when it sends it.
- **Rationale**: One codec keeps storage small and code simple. The hardware HEVC encoder on Apple silicon keeps three displays inside the 2 s budget. Conversion for the model is a few milliseconds and belongs with the connector.
- **Alternatives**: PNG (lossless, several times larger), JPEG for the analysis copy (universal for models but a second codec to maintain). Revisit only if spec 003 shows the model cannot be fed cheaply.
- **Spike S3**: capture the three displays once, encode at 0.9, and measure time per display and bytes per picture. Confirms SC-001 feasibility and the size estimate in the plan, and that text stays readable (look at one crop of a non-sensitive window).
- **S3 outcome (2026-09-30, done)**: per display, capture 58 to 179 ms (the first includes warm-up); HEIC 0.9 of the full 3440x1440 picture 60 to 91 ms and 372 to 650 KB; 2048-long-edge copy 58 to 62 ms and 187 to 295 KB. Three displays total about 2.2 MB per capture (about 0.75 MB per display), well under the 2 MB per display estimate for this screen content (busier screens will be larger; revisit if the real figure exceeds it). Sequential time is about 0.7 s for three displays, so SC-001 (2 s) has a wide margin even before encoding in parallel. Readability of text was not inspected by eye (it would show the user's screens); spec 004 measures reading accuracy on the stored pictures.

## R4. Downscaling the analysis copy

- **Decision**: Draw the full image into a smaller `CGContext` with high interpolation quality so the longer side equals the configured value; never enlarge (`min(configured, original)`); keep the aspect ratio and the color space. `ImageEncoding` owns this and has tests with synthetic images that check the pixel sizes (SC-003).
- **Alternatives**: Re-decoding the HEIC thumbnail (extra decode), vImage (more code for no visible gain).

## R5. On-disk layout and atomic writes

- **Decision**: Everything under `~/Library/Application Support/Memorri/`:
  - `memorri.sqlite` (and its `-wal`/`-shm` files)
  - `captures/<yyyy-MM>/<eventID>/<imageID>-full.heic` and `<imageID>-model.heic`
  - `staging/<uuid>/` for captures being written
  Paths are stored relative to the folder. A capture is written into `staging/<uuid>/`, then the directory is renamed into `captures/…/<eventID>/` (a rename on the same volume is atomic), and only then are the records inserted in one database transaction. If the transaction fails the directory is removed. At start, `staging/` is emptied and any `captures/…` directory without a record is removed (FR-014); a record whose file is missing is marked `missing`.
- **Rationale**: A crash at any point leaves either nothing or a complete capture, never a record without pictures or a half-written folder (spec edge cases). One event per folder makes deleting a capture a single directory removal.
- **Alternatives**: Writing files in place and cleaning up after failures (a crash could leave garbage and records pointing to nothing), storing pictures inside SQLite (bloats the database and breaks simple file deletion).
- Recorded as ADR 0009.

## R6. Private folder and backup exclusion

- **Decision**: Create the folder with POSIX mode 0700 (FR-012). Mark it excluded from backups with `URLResourceValues.isExcludedFromBackup = true`, which sets the sticky exclusion attribute that Time Machine honours. Verify with `tmutil isexcluded` in the quickstart.
- **Rationale**: Screenshots of work sessions must not be copied to a backup disk by accident. The folder mode keeps other user accounts out; FileVault covers the disk.
- **Alternatives**: `tmutil addexclusion` (external tool, may need admin rights for the fixed-path form).
- **Spike S4**: create the folder, set both, and check `tmutil isexcluded` and `ls -ld`.
- **S4 outcome (2026-09-30, done)**: a directory created under `~/Library/Application Support` with mode 0700 and `URLResourceValues.isExcludedFromBackup = true` shows `drwx------` and `tmutil isexcluded` reports `[Excluded]` (before setting it reported `[Included]`; the extended attribute `com.apple.metadata:com_apple_backup_excludeItem` is set). Decision R6 stands. (A first attempt under `/private/tmp` was meaningless because that path is excluded by default.)

## R7. Free-space floor

- **Decision**: `DiskSpaceChecking.freeBytes(at:)` reads `volumeAvailableCapacityKey` (strictly free space, not counting purgeable) for the volume that holds the data folder. The pipeline refuses to capture when it is below `1_073_741_824` bytes (FR-022) and reports "Not enough free disk space". A debug-only launch argument `--simulate-free-bytes <n>` lets the quickstart and UI automation test the refusal without filling a disk.
- **Alternatives**: `volumeAvailableCapacityForImportantUsageKey` (counts space macOS can reclaim, too optimistic for a refusal rule).

## R8. Database: GRDB `DatabasePool`, migrations, newer and damaged files

- **Decision**: GRDB pinned to exactly 7.11.1. `DatabasePool` (WAL) with foreign keys on; migrations registered with `DatabaseMigrator` ("v1" creates both tables and the indexes). On open:
  - if `migrator.hasBeenSuperseded(db)` is true the database came from a newer app, so it is not modified and the app reports it (FR-013);
  - if opening fails with a not-a-database or corrupt error, the file (with its `-wal`/`-shm`) is renamed to `memorri.sqlite.damaged-<yyyyMMdd-HHmmss>`, a new database is created, and the user is told once (FR-019); the damaged file is never deleted.
- **Rationale**: Uses exactly the API the library documents for these cases (`hasBeenSuperseded`, `hasCompletedMigrations`).
- **Alternatives**: Plain `sqlite3` (more code for migrations and concurrency), Core Data/SwiftData (heavier, not the decision in ADR 0003).

## R9. Storage figures that match the disk

- **Decision**: `StorageStats` reads the number of captures from SQL and the space from the files themselves (size of every file under `captures/` plus the database files), computed each time the Storage section is opened (FR-015). Walking a few thousand files is fast enough; results are computed off the main actor.
- **Rationale**: SC-006 asks for figures within 1% of the real disk use; summing the recorded `bytes` columns could drift if files change outside the app.
- **Alternatives**: Trusting the stored byte counts (cheaper, but can disagree with the disk).

## R10. Retention and cleanup

- **Decision**: `CleanupService` and `RetentionService` share one delete path: select the events older than the cutoff, delete their rows in one transaction (images cascade), then remove their directories; the start-up sweeper clears any leftover directory if the app stops in between. "Delete all captures" is the same with no cutoff. A capture in progress is not in the database yet (R5), so it cannot be deleted by a cleanup. `RetentionService.runIfDue` runs at start and then a check every hour runs the policy when 24 hours have passed since the last run (`memorri.retention.lastRun`).
- **Rationale**: One code path means one set of tests for every kind of deletion, and it never touches anything derived from captures (FR-023, ADR 0010).
- **Alternatives**: A daily wake-up timer (misses a sleeping Mac), deleting files first (a crash would leave records without pictures).

## R11. Settings rules

- **Decision**: `StorageSettings` holds the analysis copy size (512 to 4096, default 2048, out-of-range input is rejected and the previous value kept, FR-005) and the retention policy (`forever` or `days(n)`, n from 1 to 3650, default `days(7)`). Shortening the policy reports how many captures it would remove before applying (FR-018). Stored in `UserDefaults` through the existing `SettingsStore`.

## R12. One capture at a time and how it connects to spec 001

- **Decision**: `CapturePipeline` is an actor with an `isRunning` flag; a second `run` while one is in progress returns `nil` at once (FR-011). `CaptureRequestService` keeps its 300 ms double-press debounce, then calls the pipeline and plays feedback from the outcome: success flash and sound for `complete`, warning flash and sound for `partial` and `failed`, nothing for `permissionDenied` (the onboarding window opens instead). Its in-memory request history stays for diagnostics.
- **Rationale**: Reuses the debounce and feedback switches already tested in 001 and changes only what happens after a request is accepted.

## R13. The last capture result line

- **Decision**: `AppState.lastCaptureResult` holds complete / partial(captured, of) / failed(reason) with the time; the menu shows it as the first line, for example "Last capture: complete, 2 min ago" (strings in the UI contract). A light timer in `AppState` updates the relative time every 30 seconds. No notifications, no alert windows (FR-021).

## R14. Testing on this Mac

- **Decision**: Unit tests cover everything that does not need a real screen. For the platform parts the assistant can now drive the app (menu clicks, key presses, log reading) with the Accessibility and Screen Recording access granted to VS Code, and inspect files with `ls`, `sqlite3` and `tmutil`. The remote-desktop case and a human look at a stored picture stay manual. Looking at a stored picture means viewing the user's own screen content, so it is done only on a prepared test screen and with the user's consent.
