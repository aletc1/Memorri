feat(items): month calendar view and a one-row header (spec 012)

## What
- The Items window can show a month calendar next to the detail pane. Each item is a chip in the cell of its day (an appointment on its start day, a to-do on its due day, else its start), in the item's own time zone. Undated items sit under the grid.
- The header is one row: List/Calendar switch, Show (Items, Inbox (N), Approved), Kind and Context menus, dismissed toggle, search, then icon actions (check, X or restore, merge) only when the selection allows them, and an icon-only Undo.
- The view and the month are remembered. The calendar uses the same filtered rows and the same selection as the list.

## Why
Most items have dates, and two rows of segmented controls were hard to scan.

## Design
No calendar package: HorizonCalendar is iOS-only, MijickCalendarView is a date picker, `DatePicker` shows nothing in a day (ADR 0024). The grid maths is pure code in `MemorriCore` (`ItemCalendar`), tested; the cells are SwiftUI.

Spec: `specs/012-items-calendar-view/`. ADR: 0024.

## Verification
- `swift test --package-path Packages/MemorriCore`: 1318 tests pass, 14 new in `ItemCalendarTests` (pinning, zones, order, +N more, weeks, filters equal the list, 5,000 items under 200 ms).
- App builds. The UI was checked by the author in the running app on the real library (header, calendar, filters, fixed detail width, tooltips).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
