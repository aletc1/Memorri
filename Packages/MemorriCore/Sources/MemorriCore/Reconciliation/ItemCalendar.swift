import Foundation

/// A calendar day with no time zone: the day an item is pinned to, in the item's own zone.
public struct CalendarDay: Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    /// `2026-10-14`.
    public var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init?(text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// `2026-10`, what the window remembers for the month in view.
    public var monthText: String { String(format: "%04d-%02d", year, month) }

    public init?(monthText: String) {
        let parts = monthText.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: 1)
    }

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// One item as a cell shows it.
public struct CalendarChip: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// `09:00` in the item's zone; nil for an all-day item.
    public let time: String?
    public let kind: FindingKind
    public let needsReview: Bool
    public let dimmed: Bool

    /// What VoiceOver says: `Appointment, Standup, 09:00, needs review`.
    public var spokenLabel: String {
        let name: String
        switch kind {
        case .appointment: name = "Appointment"
        case .task: name = "Task"
        case .reminder: name = "Reminder"
        case .deadline: name = "Deadline"
        }
        return ([name, title, time ?? "all day"] + (needsReview ? ["needs review"] : [])).joined(separator: ", ")
    }
}

public struct CalendarCell: Sendable, Equatable, Identifiable {
    public let day: CalendarDay
    /// False for the days of the neighbouring months that fill the first and last week.
    public let inMonth: Bool
    public let isToday: Bool
    /// Every item pinned to the day, in order.
    public let chips: [CalendarChip]
    public var id: CalendarDay { day }
    public var shown: [CalendarChip] { Array(chips.prefix(ItemCalendar.visibleLimit)) }
    public var hiddenCount: Int { max(0, chips.count - ItemCalendar.visibleLimit) }
}

public struct MonthGrid: Sendable, Equatable {
    /// The first day of the month.
    public let month: CalendarDay
    /// `October 2026`.
    public let title: String
    /// Short weekday names, starting at the first weekday.
    public let weekdays: [String]
    public let weeks: [[CalendarCell]]
    /// Items with no start or due date.
    public let undated: [CalendarChip]
}

/// The month view of the Items window as pure logic (spec 012): which day each item is on and what the grid holds.
public enum ItemCalendar {
    /// Chips shown in a cell before `+N more`.
    public static let visibleLimit = 3

    private static func calendar(_ zone: TimeZone, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func zone(_ item: Item) -> TimeZone { TimeZone(identifier: item.timezone) ?? TimeZone(identifier: "UTC")! }

    /// Calendars and time formatters made once per zone while a grid is built (a month of thousands of items shares a few zones).
    private final class Zones {
        private var calendars: [String: Calendar] = [:]
        private var formatters: [String: DateFormatter] = [:]

        func calendar(_ item: Item) -> Calendar {
            if let hit = calendars[item.timezone] { return hit }
            let made = ItemCalendar.calendar(ItemCalendar.zone(item)); calendars[item.timezone] = made; return made
        }

        func time(_ item: Item, _ moment: Date) -> String {
            let formatter: DateFormatter
            if let hit = formatters[item.timezone] { formatter = hit } else {
                formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = ItemCalendar.zone(item)
                formatter.dateFormat = "HH:mm"
                formatters[item.timezone] = formatter
            }
            return formatter.string(from: moment)
        }
    }

    /// The day an item is pinned to: the day of its start (event) or due date (to-do, else its start) in its own zone; nil when undated.
    public static func day(of item: Item) -> CalendarDay? { day(of: item, zones: Zones()) }

    private static func day(of item: Item, zones: Zones) -> CalendarDay? {
        guard let moment = ItemListModel.moment(item) else { return nil }
        let parts = zones.calendar(item).dateComponents([.year, .month, .day], from: moment)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    public static func chip(_ item: Item) -> CalendarChip { chip(item, zones: Zones()) }

    private static func chip(_ item: Item, zones: Zones) -> CalendarChip {
        var time: String?
        if !item.allDay, let moment = ItemListModel.moment(item) { time = zones.time(item, moment) }
        return CalendarChip(id: item.id, title: item.title, time: time, kind: item.kind, needsReview: item.needsReview, dimmed: item.status == .dismissed)
    }

    /// All-day first, then by time, then title, then id.
    private static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            let (x, y) = (ItemListModel.moment(a), ItemListModel.moment(b))
            if let x, let y, x != y { return x < y }
            let order = a.title.localizedCaseInsensitiveCompare(b.title)
            return order != .orderedSame ? order == .orderedAscending : a.id < b.id
        }
    }

    /// The first day of the month `count` months after (or before, when negative) `month`.
    public static func shift(_ month: CalendarDay, by count: Int) -> CalendarDay {
        let index = month.year * 12 + (month.month - 1) + count
        return CalendarDay(year: index.quotientAndRemainder(dividingBy: 12).quotient, month: index.quotientAndRemainder(dividingBy: 12).remainder + 1, day: 1)
    }

    public static func firstOfMonth(_ day: CalendarDay) -> CalendarDay { CalendarDay(year: day.year, month: day.month, day: 1) }

    /// The day `today` is in `zone`.
    public static func today(_ now: Date = Date(), zone: TimeZone = .current) -> CalendarDay {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: now)
        return CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The month's weeks (the first weekday is `firstWeekday`, 1 = Sunday … 7 = Saturday) with the rows' items on their days.
    public static func grid(rows: [ItemRow], month: CalendarDay, today: CalendarDay, firstWeekday: Int = 2) -> MonthGrid {
        let utc = calendar(TimeZone(identifier: "UTC")!, firstWeekday: firstWeekday)
        let first = firstOfMonth(month)
        let start = utc.date(from: DateComponents(year: first.year, month: first.month, day: 1))!
        let length = utc.range(of: .day, in: .month, for: start)!.count
        let offset = (utc.component(.weekday, from: start) - firstWeekday + 7) % 7
        let weekCount = (offset + length + 6) / 7

        let zones = Zones()
        var byDay: [CalendarDay: [Item]] = [:]
        var undated: [Item] = []
        for row in rows {
            if let day = day(of: row.item, zones: zones) { byDay[day, default: []].append(row.item) } else { undated.append(row.item) }
        }

        let weeks: [[CalendarCell]] = (0..<weekCount).map { week in
            (0..<7).map { column in
                let date = utc.date(byAdding: .day, value: week * 7 + column - offset, to: start)!
                let parts = utc.dateComponents([.year, .month, .day], from: date)
                let day = CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!)
                return CalendarCell(day: day, inMonth: day.year == first.year && day.month == first.month, isToday: day == today,
                                    chips: ordered(byDay[day] ?? []).map { chip($0, zones: zones) })
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "LLLL yyyy"
        let symbols = formatter.shortWeekdaySymbols ?? []
        let weekdays = symbols.isEmpty ? [] : (0..<7).map { symbols[(firstWeekday - 1 + $0) % 7] }
        return MonthGrid(month: first, title: formatter.string(from: start), weekdays: weekdays, weeks: weeks, undated: ordered(undated).map { chip($0, zones: zones) })
    }

    /// The month an item is pinned in, for moving the view to a selected item; nil when undated.
    public static func month(of item: Item) -> CalendarDay? { day(of: item).map(firstOfMonth) }
}
