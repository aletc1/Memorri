# 2026-10-02: Settings > Diagnostics drew an empty window

## Summary
Choosing Diagnostics in Settings showed a white window with no sidebar and no page. Removing one layout modifier on the page's description text fixed it.

## Impact
Spec 010's Diagnostics page (report, save as text or JSON) could not be used, and the sidebar vanished with it, so the user could not leave the page. No data was affected.

## Timeline
- Spec 010 merged with a Diagnostics page whose tests covered the report, not the drawing.
- The user opened Diagnostics and saw a blank window.
- Reproduced on the merged code (macOS 27.0.1): the accessibility tree held the full report while the window drew nothing, other pages drew normally, and the process was idle (no crash, no hang, no log line).
- Bisected by replacing parts of the page: a stub body drew; the original without the load task still did not; without the scroll view it did not; without the description text it drew; the original with only the description's `fixedSize` removed drew everything.

## Root cause
The description text above the report used `.fixedSize(horizontal: false, vertical: true)` in a column that also holds a scroll view meant to take the remaining height, inside the detail column of the split view. With that combination the hosting view never produced a drawable layout and drew nothing, sidebar included. Other pages use the same modifier next to no scroll view. I did not find why the layout fails; the finding comes from bisecting.

## Fix
The description text wraps by the column width without `fixedSize`. The page was checked in the running app by screenshot of the window.

## Follow-ups
- [ ] A drawing check cannot be unit tested (there is no App test target); the quickstart of any spec that adds a Settings page should list "open the page and see it" as a step.
