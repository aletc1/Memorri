# Quickstart: validate spec 002

Run on a Mac with macOS 26+, after implementation. Most steps can be driven from a terminal with the UI automation available on the developer Mac (Accessibility and Screen Recording granted to VS Code); the ones marked **manual** need a person. Interfaces are in [contracts/](contracts/), the schema and lifecycle in [data-model.md](data-model.md).

## Prerequisites

1. Spec 001 is working (see `specs/001-menubar-shell/quickstart.md`). The signing identity exists and Memorri has Screen Recording permission.
2. A terminal, with `sqlite3`, `tmutil` and `/usr/bin/log` available (all ship with macOS).
3. Shorthands used below:
   ```bash
   APP=.build/xcode/Build/Products/Debug/Memorri.app
   DATA="$HOME/Library/Application Support/Memorri"
   DB="$DATA/memorri.sqlite"
   ```
4. To start from nothing: quit Memorri, then `rm -rf "$DATA"`. (This deletes stored captures. Do it only on a test Mac or test data.)

## Build and unit tests

```bash
xcodegen generate
xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build
swift test --package-path Packages/MemorriCore
open $APP
```

Expected: build succeeds, all tests pass, the icon appears.

## Scenario 1: capture every display (User Story 1)

Open a second terminal: `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri"'`.

| Step | Expected |
|---|---|
| Note the number of displays (`system_profiler SPDisplaysDataType \| grep -c Resolution`). Press Control+Option+Command+M (or run `osascript -e 'tell application "System Events" to key code 46 using {control down, option down, command down}'`). | Flash and sound within 2 s. Log: `capture finished status=complete displays=<n> images=<n>`. |
| `sqlite3 "$DB" "select status, display_count from capture_events order by captured_at desc limit 1; select count(*) from capture_images where event_id=(select id from capture_events order by captured_at desc limit 1);"` | `complete\|<n>` and `<n>` images: one per display. |
| `find "$DATA/captures" -name '*.heic' \| wc -l` | `2 × <n>` files (full and analysis copy for each). |
| `sips -g pixelWidth -g pixelHeight "$DATA"/captures/*/*/*-full.heic` | Each full picture has the display's native pixel size. |
| Same for `*-model.heic` | Longer side is 2048 (or the display's own size when smaller). |
| Top of the menu | `Last capture: complete, just now`. |
| Press the shortcut twice within 300 ms | One new event only. A press during a running capture adds none. |
| **Manual (a person looks at one stored picture of a prepared test screen)** | No mouse pointer in the picture. The pictures match the displays. |

## Scenario 2: refused capture fixes the permission state (User Story 2)

| Step | Expected |
|---|---|
| With the app running and granted, run `tccutil reset ScreenCapture com.aletc1.memorri`. Do not open any Memorri window. Press the shortcut. | No flash or sound. The onboarding window opens within 2 s. |
| Log and database | Log: `capture refused reason=permission`. `select status from capture_events order by captured_at desc limit 1;` gives `failed`, and no new `.heic` files exist. |
| Menu | Shows "Grant Screen Recording access…". Permission status reads Not granted. |
| Grant again, relaunch, capture | A normal complete capture. Status reads Granted (the capture confirmed it). |

## Scenario 3: other failures and the free-space floor

| Step | Expected |
|---|---|
| Quit and start the app with `open -n $APP --args --simulate-free-bytes 500000000` (Debug build). Capture. | Warning flash and sound. Menu line `Last capture failed: Not enough free disk space, just now`. No pictures stored, a failed event recorded. |
| Start again with `--simulate-free-bytes 2000000000`. | Normal capture. |
| Repeat the refusal 5 times | Refused every time (SC-011). |

## Scenario 4: stored safely, survives restarts, private (User Story 3)

| Step | Expected |
|---|---|
| Make 3 captures, then quit and launch 3 times; each time `sqlite3 "$DB" "select count(*) from capture_events;"` | The same count each time, and the pictures still exist. |
| `ls -ld "$DATA"` | Mode `drwx------` (0700), owned by the current user. |
| `tmutil isexcluded "$DATA"` | `[Excluded]`. |
| Quit. Create a leftover: `mkdir -p "$DATA/staging/leftover" "$DATA/captures/2026-01/orphan"`. Start the app. | Both directories are gone (log: `reconcile …`). |
| Quit. Delete one `*-full.heic` by hand. Start the app. | The app starts; the record is marked missing (`select missing from capture_images;`), nothing crashes. |
| Quit. `cp "$DB" /tmp/db.bak; printf 'garbage' > "$DB"`. Start the app. | A dialog says the database was set aside; `ls "$DATA"` shows `memorri.sqlite.damaged-…`; a new database exists; capturing works. Restore with `mv` afterwards if the old data matters. |

## Scenario 5: storage figures and cleanup (User Story 4)

1. Open Settings, Storage. The count equals `select count(*) from capture_events;`. Pictures size is within 1% of `du -sk "$DATA/captures"` (SC-006).
2. Backdate some captures: `sqlite3 "$DB" "update capture_events set captured_at = datetime('now','-40 days') where id in (select id from capture_events order by captured_at limit 2);"` and move their folders to the matching month if needed.
3. Enter 30 in `Delete captures older than`, click **Delete…**. The dialog names the count and size, says items found in them are kept. Cancel: nothing changes. Confirm: only the backdated captures and their folders are gone; the numbers update (SC-007).
4. **Delete all captures…**, confirm: no events, no files under `captures/`, the numbers show zero.

## Scenario 6: retention policy (User Story 5)

1. Storage shows `For 7 days` by default.
2. Backdate 2 captures by 40 days as above, relaunch. They are gone at start; newer ones stay. Log: `retention removed=2`.
3. Choose `Forever`, backdate again, relaunch: nothing removed.
4. Choose `For 1 days` with older captures present: the dialog says how many will be removed now; confirming removes them at once.

## Scenario 7: analysis copy size (User Story 6)

1. Storage shows 2048. Set 1024, capture: the new `*-model.heic` files have a longer side of 1024; older captures are unchanged.
2. Enter 100: `Enter a value between 512 and 4096.`, the value stays 1024. Set 2048 again.
3. On a display smaller than the size, the analysis copy equals the original (not enlarged).

## Scenario 8: remote-desktop client (manual, acceptance)

With the real remote-desktop client full-screen, press the shortcut 10 times, a second apart. Expected: every press gives a complete capture, the display with the client shows its full-screen content in the stored picture, and the menu line stays `complete`. Record the result in the table below.

| Client | Captures | Complete | Display shows the session | Result |
|---|---|---|---|---|
| Windows App | 11 shortcut presses (2026-09-30, 08:47:47 to 08:48:07 UTC) | 11 of 11 (3 images each, none failed; read from the database) | yes, the full-screen session is visible in the stored picture (confirmed by the user) | pass |

### Observed on the developer Mac (2026-09-30, scenarios 1 to 7, driven from the terminal)

| Check | Result |
|---|---|
| SC-001 time to finish a capture of 3 displays | about 300 to 390 ms (log `ms=`) |
| SC-002 20 consecutive captures | 20 of 20 complete, 3 images each, 144 files for 72 images, none missing |
| SC-003 analysis copy sizes | 2048x857 from 3440x1440; 1024x429 after the setting changed; older captures unchanged |
| SC-004 revoke while running, then capture | refused in 25 ms, onboarding opened, status not granted, nothing stored (run once; 5 trials not repeated) |
| SC-005 three relaunches | 24 events and 72 images each time, none missing |
| SC-006 figures against the disk | 560 KB shown, `du -sk` 560 |
| SC-007 cleanup | only the older captures and their folders removed; delete all leaves zero events and zero files |
| SC-008 private and excluded | `drwx------`, `tmutil isexcluded` reports `[Excluded]` |
| SC-011 free-space refusal | 5 of 5 refused, no pictures |
| SC-012 pointer never shown | not checked by eye (the pictures would show the screen); `showsCursor = false` is set |
| FR-020 network | `lsof -i` shows 0 connections |

## No network and no leftovers

`lsof -i -a -p $(pgrep -x Memorri)` shows nothing. The no-network source scan test passes over the new code.
