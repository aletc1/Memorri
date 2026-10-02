# Tasks: items calendar view (spec 012)

## Phase 1: Core (tests first)
- [X] T001 [US2] Write `ItemCalendarTests` (pinning in item zone, start vs due, undated, order, +N more, weeks and first weekday, today, month shift, filters equal list) in Packages/MemorriCore/Tests/MemorriCoreTests/ItemCalendarTests.swift
- [X] T002 [US2] Implement `ItemCalendar` (`CalendarDay`, `CalendarChip`, `CalendarCell`, `MonthGrid`) and make `ItemListModel.moment` public in Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemCalendar.swift
- [X] T003 [US3] Test and add scale check (5,000 items) in ItemCalendarTests.swift

## Phase 2: One-row header (US1)
- [X] T004 [US1] Rebuild the header as one row with Show menu, icon actions, icon Undo in App/Windows/ItemsView.swift
- [X] T005 [US1] Kind control is a menu (a segmented control does not fit one row); the window's smallest width becomes 860

## Phase 3: Calendar view (US2, US3)
- [X] T006 [US2] `CalendarMonthView` with month header, Today, cells, chips, `+N more` popover, `No date` strip in App/Windows/CalendarMonthView.swift
- [X] T007 [US2] View switch, shared selection, Command-click, month follows a selected item in ItemsView and ItemsViewModel
- [X] T008 [US3] Remember view and month (`@AppStorage`)
- [X] T009 [US3] Accessibility labels, Command-arrow month keys

## Phase 4: Polish
- [X] T010 Checked by the user in the running app on the real library (header in one row, calendar, filters, fixed detail width, tooltips); not repeated in an isolated home at default and smallest width, screenshot by window id, check every quickstart step
- [X] T011 Update roadmap, CLAUDE.md active plan, DEVELOPER.md note, PR description
