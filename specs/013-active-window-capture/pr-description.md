feat(capture): capture only the active window, with its own shortcut and a red outline (spec 013)

## What
- A second global shortcut, **Capture window** (Control+Option+Command+W by default, changeable in Settings, also in the menu), captures only the active window: the front-most ordinary window of the frontmost application, never one of Memorri's own. No Accessibility permission is used.
- The picture is the screen inside the window's outline, so anything drawn over the window is in it and nothing hidden is recovered. It is stored as one capture (`scope = window`, migration `v13`) with one picture, one recorded window that fills it, and the window's frame on the desktop.
- It is analysed as one chosen window: the windows call still decides the kind of view, but its relevance answer is replaced with "relevant"; the reference clock looks only inside the window and never flags a missing clock; the window's name reaches sightings and evidence. Findings reconcile with every other capture's, so the same event seen in a window capture and a full-screen capture is one item with two sightings. Reprocessing trials and the library re-read use the same scope.
- After a successful capture a red outline of the recorded area is shown on each display it touches for about a second. It is click-through, takes no focus, is left out of screen sharing, is created after the picture is stored, and is not shown when the capture fails.
- The full-screen capture, its shortcut and "Capture now" are unchanged. Window and full-screen captures share the busy flag and the double-press rule.
- The new shortcut is checked against the other two and macOS; if the user already uses Control+Option+Command+W for another action, the window shortcut starts unassigned and says why.

## Why
The user often knows which window matters. A narrow capture costs less analysis time, brings in nothing from other windows, and the outline shows exactly what was taken.

## Spec and decisions
`specs/013-active-window-capture/` (spec, plan, research, data model, contracts, quickstart, tasks). ADR 0028.

## How it was verified
- `swift test --package-path Packages/MemorriCore`: 1594 tests pass in the new and changed suites; the full suite also shows `NewItemsNotifierTests.itemsThatBecamePossiblyCancelledAreAnnouncedAndCountAmongThoseNeedingReview` failing now and then. It fails the same way on the spec 010 checkout without any 013 code (1 pass and 1 failure in two full runs) and passes alone: a timing-dependent test from spec 010, not changed here.
- Existing tests were touched only to compile: new fixture parameters, named columns in four raw inserts, and the column lists of the schema test.
- `memorri-eval`: before and after on the same model. The 33 existing cases: `compare` reports no case changed. Five new `window-capture-*` cases: right kinds and dates; one false reminder from a panel drawn over a calendar (recorded in research as a known limit). Model calls 65 to 74, exactly the five new cases. Mean seconds per window case is at or below the baseline mean.
- By hand in a Debug build on three displays, in an isolated home: menu item and the real shortcut both store a window capture of the right window; the full-screen capture still stores 3 displays with scope `displays`; a window straddling two displays gives a picture of the rectangle; a window in its own full-screen Space is captured whole, and the outline panel is on screen over it at the recorded frame; zero red pixels in stored pictures, including one taken while the previous outline was showing; the menu and Settings show the new shortcut. Preferences changed by the test runs were restored.

## Still to look at
- The red outline over a full-screen app, by eye (it is excluded from screenshots, so it was checked through the window list).
- Displays of different scales (all three displays here are 1x).
- Recording a conflicting shortcut in the Settings recorder and a restart (the rules are unit-tested; the recorder cannot be driven from outside).
- Merge order: this branch is based on `main` with specs 009 and 010; the migration is `v13`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
