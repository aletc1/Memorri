# Data model: items calendar view (spec 012)

No stored data changes. Derived values in `MemorriCore` (`Reconciliation/ItemCalendar.swift`):

- `CalendarDay` (year, month, day): Comparable, Hashable, `yyyy-MM-dd` text; the day of an item in its own zone.
- `CalendarChip`: item id, title, time text (nil for all day), kind, needsReview, dimmed, spoken label.
- `CalendarCell`: day, inMonth, isToday, chips (all, in order), `shown`, `hiddenCount`.
- `MonthGrid`: month (first day), weeks `[[CalendarCell]]` (5 or 6 rows of 7), title (`October 2026`), weekday symbols, `undated` chips.
- Preference (UserDefaults): `items.viewMode`, `items.month`.

Rules: pinned day = day of `ItemListModel.moment` in the item's zone; order in a day = all day first, then time, then title, then id; `shown` = first `visibleLimit`; `hiddenCount` = rest; weeks start on the given first weekday and run until the month's last day is covered.
