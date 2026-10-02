# Research: items calendar view (spec 012)

## R1. Calendar component
Decision: no package; Foundation `Calendar` for the maths, SwiftUI `Grid` for the cells. See ADR 0024 (HorizonCalendar is iOS-only, MijickCalendarView is a picker, `DatePicker` shows nothing in cells).

## R2. Which day an item is pinned to
Decision: the day of `ItemListModel.moment(item)` (start for events, due else start for to-dos) read in the item's own time zone, so it is the day the list prints. The remind date does not pin. No moment: listed under `No date`. An item spanning days is pinned on its start day only.

## R3. Same items as the list
Decision: the calendar takes `visibleRows` (filters, scope, search) and only changes the arrangement, so the sets are equal by construction (SC-002). The Inbox's last-seen ordering does not apply: chips are ordered inside the day by all-day first, time, title.

## R4. Header in one row
Decision: one `HStack`: view switch, kind, context, Show menu, dismissed toggle, search, spacer, action icons, Undo. Kind becomes a menu too: a segmented control of four labels does not fit one row at 860 points. The window's smallest width grows from 720 to 860 so the calendar (480) fits beside the detail (340). Actions stay SF Symbols with `.help` and accessibility labels.

## R5. Remembering view and month
Decision: `@AppStorage` keys `items.viewMode` (`list` or `calendar`) and `items.month` (`yyyy-MM`) in the window view; a bad or missing value falls back to list and the current month.

## R6. Selection
Decision: one `selection` set in `ItemsViewModel` for both views. A click on a chip selects it, Command-click toggles it (two items can be merged). Switching view keeps the set. When an item is selected from elsewhere (search, menu) the calendar moves to its month.

## R7. Many items on a day
Decision: a cell shows `visibleLimit` chips (3), the rest as `+N more` opening a popover with the day's full list.
