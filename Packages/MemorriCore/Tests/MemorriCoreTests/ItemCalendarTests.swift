import Foundation
import Testing
@testable import MemorriCore

/// The month view as logic (spec 012): which day each item is on, the order in a cell, the weeks of a month and what the filters leave.
@Suite struct ItemCalendarTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ text: String, zone: String = "UTC") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func row(_ id: String, _ kind: FindingKind = .appointment, title: String? = nil, start: String? = nil, due: String? = nil, allDay: Bool = false,
                     zone: String = "UTC", status: ItemStatus = .active, needsReview: Bool = false) -> ItemRow {
        let item = Item(id: id, kind: kind, status: status, title: title ?? "Item \(id)", allDay: allDay,
                        start: start.map { date($0, zone: zone) }, due: due.map { date($0, zone: zone) }, timezone: zone, confidence: 0.9,
                        firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0), needsReview: needsReview)
        return ItemRow(item: item, sightingCount: 1, locked: false, possibleDuplicate: false)
    }

    private let october = CalendarDay(year: 2026, month: 10, day: 1)
    private let today = CalendarDay(year: 2026, month: 10, day: 13)

    private func cell(_ grid: MonthGrid, _ day: Int) -> CalendarCell {
        grid.weeks.flatMap { $0 }.first { $0.inMonth && $0.day.day == day }!
    }

    @Test func anEventIsOnItsStartDayAndAToDoOnItsDueDay() {
        let grid = ItemCalendar.grid(rows: [row("a", start: "2026-10-13 10:00"), row("b", .task, due: "2026-10-13 17:00"), row("c", .task, start: "2026-10-20 09:00"),
                                            row("d", .reminder, due: "2026-10-21 09:00")], month: october, today: today)
        #expect(cell(grid, 13).chips.map(\.id) == ["a", "b"])
        #expect(cell(grid, 20).chips.map(\.id) == ["c"])          // a to-do without a due date falls back to its start
        #expect(cell(grid, 21).chips.map(\.id) == ["d"])
    }

    @Test func theDayIsTheDayInTheItemsOwnZone() {
        // 23:30 in Tokyo on the 13th is 14:30 UTC on the same day; 00:30 in Tokyo on the 14th is 15:30 UTC on the 13th.
        let tokyoLate = row("t", start: "2026-10-14 00:30", zone: "Asia/Tokyo")
        #expect(ItemCalendar.day(of: tokyoLate.item) == CalendarDay(year: 2026, month: 10, day: 14))
        let grid = ItemCalendar.grid(rows: [tokyoLate], month: october, today: today)
        #expect(cell(grid, 14).chips.map(\.id) == ["t"] && cell(grid, 13).chips.isEmpty)
        #expect(cell(grid, 14).chips.first?.time == "00:30")
    }

    @Test func anItemSpanningDaysIsOnlyOnItsStartDay() {
        var spanning = row("s", start: "2026-10-13 22:00")
        spanning = ItemRow(item: { var i = spanning.item; i.end = date("2026-10-14 02:00"); return i }(), sightingCount: 1, locked: false, possibleDuplicate: false)
        let grid = ItemCalendar.grid(rows: [spanning], month: october, today: today)
        #expect(cell(grid, 13).chips.count == 1 && cell(grid, 14).chips.isEmpty)
    }

    @Test func allDayComesFirstThenTimeThenTitle() {
        let grid = ItemCalendar.grid(rows: [row("late", start: "2026-10-13 15:00"), row("early", start: "2026-10-13 08:00"), row("day", start: "2026-10-13 00:00", allDay: true),
                                            row("tieB", title: "Beta", start: "2026-10-13 12:00"), row("tieA", title: "Alpha", start: "2026-10-13 12:00")], month: october, today: today)
        #expect(cell(grid, 13).chips.map(\.id) == ["day", "early", "tieA", "tieB", "late"])
        #expect(cell(grid, 13).chips.first?.time == nil)
    }

    @Test func aCellShowsThreeChipsAndCountsTheRest() {
        let rows = (1...7).map { row("i\($0)", start: "2026-10-13 0\($0):00") }
        let busy = cell(ItemCalendar.grid(rows: rows, month: october, today: today), 13)
        #expect(busy.shown.map(\.id) == ["i1", "i2", "i3"] && busy.hiddenCount == 4 && busy.chips.count == 7)
        let quiet = cell(ItemCalendar.grid(rows: Array(rows.prefix(3)), month: october, today: today), 13)
        #expect(quiet.hiddenCount == 0)
    }

    @Test func undatedItemsAreListedApart() {
        let grid = ItemCalendar.grid(rows: [row("n", .task), row("m", start: "2026-10-02 09:00")], month: october, today: today)
        #expect(grid.undated.map(\.id) == ["n"])
        #expect(grid.weeks.flatMap { $0 }.flatMap(\.chips).map(\.id) == ["m"])
    }

    @Test func everyDatedItemIsInExactlyOneCellOfItsMonth() {
        let rows = (1...28).map { row("d\($0)", start: String(format: "2026-10-%02d 09:00", $0)) } + [row("sep", start: "2026-09-30 09:00"), row("nov", start: "2026-11-01 09:00")]
        let grid = ItemCalendar.grid(rows: rows, month: october, today: today)
        let ids = grid.weeks.flatMap { $0 }.flatMap(\.chips).map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(ids.count == 30)                         // the neighbouring days that fill the first and last week show their items too
        #expect(grid.weeks.flatMap { $0 }.filter(\.inMonth).count == 31)
    }

    @Test func weeksStartOnTheFirstWeekdayAndCoverTheMonth() {
        let monday = ItemCalendar.grid(rows: [], month: october, today: today, firstWeekday: 2)     // 1 Oct 2026 is a Thursday
        #expect(monday.weekdays == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(monday.weeks.count == 5 && monday.weeks.allSatisfy { $0.count == 7 })
        #expect(monday.weeks[0][0].day == CalendarDay(year: 2026, month: 9, day: 28) && !monday.weeks[0][0].inMonth)
        #expect(monday.weeks[0][3].day == october && monday.weeks[0][3].inMonth)
        let sunday = ItemCalendar.grid(rows: [], month: october, today: today, firstWeekday: 1)
        #expect(sunday.weekdays.first == "Sun" && sunday.weeks[0][0].day == CalendarDay(year: 2026, month: 9, day: 27))
        let six = ItemCalendar.grid(rows: [], month: CalendarDay(year: 2026, month: 8, day: 1), today: today, firstWeekday: 2)   // 1 Aug 2026 is a Saturday, 31 days
        #expect(six.weeks.count == 6)
        let four = ItemCalendar.grid(rows: [], month: CalendarDay(year: 2026, month: 2, day: 1), today: today, firstWeekday: 2)  // 1 Feb 2026 is a Sunday… still 5 with Monday start
        #expect(four.weeks.count == 5 && four.title == "February 2026")
    }

    @Test func todayIsMarkedOnce() {
        let grid = ItemCalendar.grid(rows: [], month: october, today: today)
        #expect(grid.weeks.flatMap { $0 }.filter(\.isToday).map(\.day) == [today])
        #expect(grid.title == "October 2026")
        let other = ItemCalendar.grid(rows: [], month: CalendarDay(year: 2026, month: 3, day: 1), today: today)
        #expect(other.weeks.flatMap { $0 }.allSatisfy { !$0.isToday })
    }

    @Test func shiftingMonthsCrossesYears() {
        #expect(ItemCalendar.shift(october, by: 1) == CalendarDay(year: 2026, month: 11, day: 1))
        #expect(ItemCalendar.shift(CalendarDay(year: 2026, month: 12, day: 1), by: 1) == CalendarDay(year: 2027, month: 1, day: 1))
        #expect(ItemCalendar.shift(CalendarDay(year: 2026, month: 1, day: 1), by: -1) == CalendarDay(year: 2025, month: 12, day: 1))
        #expect(ItemCalendar.shift(october, by: -13) == CalendarDay(year: 2025, month: 9, day: 1))
        #expect(ItemCalendar.firstOfMonth(today) == october)
    }

    @Test func theRememberedMonthRoundTripsAndABadOneIsRefused() {
        #expect(CalendarDay(monthText: october.monthText) == october && october.monthText == "2026-10")
        #expect(CalendarDay(monthText: "2026-13") == nil && CalendarDay(monthText: "soon") == nil)
        #expect(CalendarDay(text: "2026-10-13") == today && today.text == "2026-10-13")
    }

    @Test func chipsCarryTheMarksAndASpokenLabel() {
        let grid = ItemCalendar.grid(rows: [row("r", .task, title: "Pay", due: "2026-10-13 17:00", needsReview: true), row("x", title: "Old", start: "2026-10-13 09:00", status: .dismissed),
                                            row("a", .deadline, title: "Day", due: "2026-10-13 00:00", allDay: true)], month: october, today: today)
        let chips = cell(grid, 13).chips
        #expect(chips.map(\.id) == ["a", "x", "r"])
        #expect(chips[0].spokenLabel == "Deadline, Day, all day")
        #expect(chips[1].dimmed && chips[1].spokenLabel == "Appointment, Old, 09:00")
        #expect(chips[2].needsReview && chips[2].spokenLabel == "Task, Pay, 17:00, needs review")
    }

    @Test func theCalendarShowsExactlyWhatTheListShows() {
        let rows = [row("a", start: "2026-10-13 10:00"), row("b", .task, due: "2026-10-14 10:00", needsReview: true), row("c", .reminder, start: "2026-10-15 10:00"),
                    row("d", .task), row("e", start: "2026-10-16 10:00", status: .dismissed)]
        for filter in [ItemFilter(), ItemFilter(kind: .tasks), ItemFilter(scope: .inbox), ItemFilter(scope: .approved), ItemFilter(showDismissed: true), ItemFilter(kind: .reminders, showDismissed: true)] {
            let visible = ItemListModel.visible(rows, filter: filter)
            let grid = ItemCalendar.grid(rows: visible, month: october, today: today)
            let pinned = grid.weeks.flatMap { $0 }.flatMap(\.chips).map(\.id) + grid.undated.map(\.id)
            #expect(Set(pinned) == Set(visible.map(\.item.id)) && pinned.count == visible.count)
        }
    }

    @Test func aMonthOfFiveThousandItemsIsBuiltQuickly() {
        let rows = (0..<5000).map { row("p\($0)", start: String(format: "2026-10-%02d %02d:%02d", $0 % 28 + 1, $0 % 24, $0 % 60)) }
        let began = Date()
        let grid = ItemCalendar.grid(rows: rows, month: october, today: today)
        #expect(Date().timeIntervalSince(began) < 0.2)
        #expect(grid.weeks.flatMap { $0 }.flatMap(\.chips).count == 5000)
    }
}
