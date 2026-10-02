# 24. Month grid from Foundation's Calendar, no calendar package

- Status: Accepted
- Date: 2026-10-02
- Related: spec 012 (`specs/012-items-calendar-view/`), ADR 0020

## Context and problem
The Items window gets a month view with each item pinned in the cell of its day. The request was to use a free calendar component if one exists, to keep hand-written code small.

## Options considered
1. HorizonCalendar (Airbnb): maintained and very capable, but UIKit-only (iOS); it does not build for macOS.
2. MijickCalendarView: SwiftUI, supports macOS, custom day views. It is a date picker (selection, ranges): day cells have a fixed small size and no layout for a list of chips, "+N more" or a per-day popover, so the part that matters would be written by hand anyway, inside someone else's layout rules, plus a dependency to pin.
3. The system `DatePicker` with `.graphical`: a month grid, but it cannot show anything inside a day.
4. Foundation's `Calendar` for the date arithmetic (weeks, first weekday, month bounds, time zones) and a SwiftUI `Grid` for the cells.

## Decision
Option 4. The grid maths is a small pure function in `MemorriCore` (`ItemCalendar`), tested; the cells are a SwiftUI `Grid`. No new dependency, no pin to maintain, full control of chips and popovers. What a package would have saved is the date arithmetic, and `Calendar` already does it.

## Consequences
- Easier: no dependency; the pinning rules and the grid are unit-tested without UI; the same item filters feed list and calendar.
- Harder: month view behaviour (keyboard, VoiceOver, layout) is ours to keep right.
- Revisit: if week or day views are wanted, look again at packages that support macOS.
