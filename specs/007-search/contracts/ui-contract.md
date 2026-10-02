# UI contract: search (spec 007)

## Menu
`Search…` replaces `Search` and shows the shortcut (`Search…   ⌃⌥⌘F`) like `Capture now`. It opens the panel.

## Quick-search panel
- Floating panel, about 640 pt wide, centred on the display with the pointer, over any app, taking keys; it closes on Escape, on losing focus and after opening a result.
- Top: a search field with the cursor in it; under it the filters as menu buttons `Kind`, `Context`, `Date` and a `Dismissed` toggle; the active ones show their value and an `x`; `Clear filters` when any is on.
- Results: `Items` section then `Captures` section. Item row: kind icon, marked title, date, context, `Dismissed` or `Needs review` tag, and `in alias` / `in notes` / `in place` / `in people` when not the title. Capture row: time and display, window (`<app> — <title>`), up to three marked lines. `Show more` at the end of a section.
- Keyboard: up and down move through all rows, Return opens, Escape closes; Tab moves to filters. Opening an item shows it in the Items window; opening a capture opens the capture viewer.
- States (also spoken): `Type at least two letters`, `Searching…` only after 400 ms without an answer, `Nothing found` (with the active filters and `Clear filters`), `Search is being prepared (n of m)`, `n captures are still waiting to be analysed` under an empty result.
- Accessibility: every row and filter has a label (`Appointment, <title>, <date>, matched in alias`); results announce their count.

## Items window
A search field above the list; typing narrows the list to matching items, ranked; clearing restores it. The kind and context controls and `Show dismissed` apply as before.

## Capture viewer
A resizable window: the whole capture with the matching lines outlined (spec 006's view), the capture's time, display and the matching lines listed beside it; when the picture is gone, the lines of text (matches marked) and `The capture is no longer stored.`

## Settings
Under the capture shortcut: `Search shortcut:` recorder (default ⌃⌥⌘F), `Reset to default`, the reason when refused (conflict with the capture shortcut or a system shortcut); clearing it leaves the menu item working.
