# Quickstart: validate spec 001

Run these on a Mac with macOS 26+, after implementation. They prove the acceptance criteria end to end. Interface details are in [contracts/](contracts/), and the state rules are in [data-model.md](data-model.md).

## Prerequisites

1. Tools installed (see `DEVELOPER.md`, section 1): `xcodegen`, Xcode.
2. Signing identity exists: `scripts/create-signing-certificate.sh`, then `security find-identity -v -p codesigning` lists "Memorri Local".
3. Optional for the remote-desktop test: your remote-desktop client and a session you are permitted to use.

## Build and run

```bash
xcodegen generate
xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Memorri.app
```

Expected: the Memorri icon appears in the menu bar within 2 seconds, and there is no Dock icon or window (SC-001).

## Automated tests

```bash
swift test --package-path Packages/MemorriCore
```

Expected: all tests pass. They cover the debounce, feedback switches, the permission state machine, shortcut validation and settings.

## Scenario 1: menu (User Story 1)

| Step | Expected |
|---|---|
| Click the icon | Menu shows Capture now, Inbox, Search, Settings…, Quit Memorri (plus "Grant Screen Recording access…" while not granted). |
| Capture now | Icon flashes and a sound plays (permission granted) or the onboarding window opens (not granted). |
| Inbox, then Search | Each opens a placeholder window stating it is not built yet. |
| Settings… | Settings opens in front with General selected. Choosing it again fronts the same window. |
| Quit Memorri | Icon disappears. |

## Scenario 2: hotkey (User Story 2)

In a second terminal: `log stream --predicate 'subsystem == "com.aletc1.memorri"'`.

| Step | Expected |
|---|---|
| Focus any other app; press Control+Option+Command+M | One `capture requested trigger=shortcut ...` line; flash and sound. |
| Press it twice within 300 ms | One line only. |
| Settings, General: record Control+Option+Command+K | New shortcut works; the old one does nothing. |
| Try recording a lone letter, then a system shortcut (for example Command+Space) | The rejection messages from the UI contract appear; the previous shortcut stays. |
| Quit and relaunch | The chosen shortcut is still in effect. |
| Reset to default | Control+Option+Command+M works again. |

## Scenario 3: permission (User Story 3)

1. Remove Memorri from System Settings → Privacy & Security → Screen Recording (and quit the app first).
2. Launch: the onboarding window opens once, status "Not granted".
3. Open System Settings from the window, enable Memorri, return: status updates within 2 seconds, and "Restart required" appears if macOS needs it. Use Relaunch.
4. Launch again after quitting: no window opens on its own; status is "Granted".
5. Revoke the permission while the app runs: within a few seconds the menu shows "Grant Screen Recording access…" again.

## Scenario 4: permission survives a rebuild (SC-003)

```bash
codesign -dr - .build/xcode/Build/Products/Debug/Memorri.app 2>&1 | tee /tmp/req-1.txt
touch App/MemorriApp.swift
xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build
codesign -dr - .build/xcode/Build/Products/Debug/Memorri.app 2>&1 | diff - /tmp/req-1.txt && echo "requirement unchanged"
```

Then relaunch. Expected: "requirement unchanged", the status is still Granted, and no prompt appears. Repeat 5 times.

Negative check: temporarily rename the identity in `project.yml` to one that does not exist. The build must fail with the message that points to `scripts/create-signing-certificate.sh` (FR-015). Restore it afterwards.

## Scenario 5: single instance

With Memorri running, run `open -n .build/xcode/Build/Products/Debug/Memorri.app`. Expected: no second icon, and the Settings window of the running app opens.

## Scenario 6: remote-desktop client (acceptance, manual)

1. Connect with your real remote-desktop client and make it full-screen.
2. Press the shortcut 20 times, waiting a second between presses; count `capture requested` lines in the log stream.
3. Record the result below. Repeat with a second shortcut if the first fails.

| Client | Shortcut | Presses | Log lines | Pass (≥ 19, no duplicates) |
|---|---|---|---|---|
| | | | | |

If no shortcut passes, stop and write a postmortem or ADR before starting spec 002.

## No network (FR-017)

While running the scenarios, confirm no connection is made: `lsof -i -a -p $(pgrep -x Memorri)` shows nothing.
