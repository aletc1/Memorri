# Quickstart: validating window capture

Prerequisites: signing identity set up (`scripts/create-signing-certificate.sh` once), Ollama running with the default model, Screen Recording granted to Memorri. Details of the pieces are in [data-model.md](data-model.md) and [contracts/](contracts/).

## 1. Automated

```sh
swift test --package-path Packages/MemorriCore
swift run --package-path Packages/MemorriCore memorri-eval generate-synthetic
swift run --package-path Packages/MemorriCore memorri-eval run        # compare with a run made before the change
```

Expected: all tests pass, including the unchanged full-screen capture tests; the five new `window-capture-*` cases score 1.00 on dates and kinds; the 33 existing cases score as before.

## 2. Build and run

```sh
xcodegen generate
xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Memorri.app
/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri"'    # in another terminal; no titles or app names appear
```

## 3. Walk through the stories

1. **Story 1.** Open a mail window in front of a calendar and a browser, on two displays. Press Control+Option+Command+W. Expect: one stored capture with one picture of the mail only; items only from the mail.
2. **Story 2.** On the same press the red border appears around the mail, within half a second, and fades after about a second. Click through it. Open the stored picture: no border in it. Repeat on a full-screen window in another Space, and on a window straddling two displays.
3. **Story 3.** Press Control+Option+Command+M and use "Capture now": every display is captured as before, no border.
4. **Story 4.** In Settings, set the window shortcut to the capture shortcut: it is refused and the old one stays. Choose "Capture window" in the menu with a window in front of another application: it captures that window.
5. **Story 5.** The menu's last-capture line says `Last window capture: <app>`; an item from the capture names the window in its detail.
6. **Edge cases.** Focus the desktop (Finder with no window), press the shortcut: warning look and sound, nothing stored. Open Memorri's own Settings window in front and press it: warning, nothing stored. Revoke Screen Recording and press it: onboarding opens.
7. **Debug ingest.** `Memorri --ingest-case eval/golden/synthetic/window-capture-mail` stores it as a window capture and queues its analysis.

## 4. Expected database state

```sh
sqlite3 -readonly "<library>/memorri.sqlite" \
  "select scope, trigger, display_count from capture_events order by captured_at desc limit 3"
```

The newest window capture shows `window`, `shortcut` or `menu`, and `1`.
