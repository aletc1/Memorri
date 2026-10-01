import Foundation

/// When something is, as matching sees it: an appointment's start and end, or a task's due time (as `start`). A nil start is undated.
public struct TimeSpan: Sendable, Equatable {
    public let start: Date?
    public let end: Date?
    public let allDay: Bool
    public let timezone: String
    public let family: KindFamily

    public init(start: Date?, end: Date?, allDay: Bool, timezone: String, family: KindFamily) {
        self.start = start; self.end = end; self.allDay = allDay; self.timezone = timezone; self.family = family
    }
}

/// Which items can be the same event as a finding, and how well the times agree (research R5).
public enum TimeAgreement {
    static let nearStart: TimeInterval = 15 * 60
    static let todoWindow: TimeInterval = 24 * 3600

    /// `YYYY-MM-DD` of a date in a time zone (UTC when the zone is unknown); nil for no date.
    public static func dayKey(_ date: Date?, timezone: String) -> String? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func isCandidate(_ a: TimeSpan, _ b: TimeSpan) -> Bool { score(a, b) > 0 }

    /// 0 for a pair that cannot be the same event.
    public static func score(_ a: TimeSpan, _ b: TimeSpan) -> Double {
        guard a.family == b.family else { return 0 }
        switch (a.start, b.start) {
        case (nil, nil): return 1
        case (nil, _), (_, nil): return 0
        case let (x?, y?):
            switch a.family {
            case .event: return eventScore(a, x, b, y)
            case .todo: return todoScore(a, x, b, y)
            }
        }
    }

    private static func eventScore(_ a: TimeSpan, _ x: Date, _ b: TimeSpan, _ y: Date) -> Double {
        guard dayKey(x, timezone: a.timezone) == dayKey(y, timezone: b.timezone) else { return 0 }
        if a.allDay && b.allDay { return 1 }
        if a.allDay || b.allDay { return 0.5 }
        if abs(x.timeIntervalSince(y)) < 1 { return 1 }
        let aEnd = max(a.end ?? x, x), bEnd = max(b.end ?? y, y)
        if x < bEnd && y < aEnd { return 0.8 }
        return abs(x.timeIntervalSince(y)) <= nearStart ? 0.6 : 0
    }

    private static func todoScore(_ a: TimeSpan, _ x: Date, _ b: TimeSpan, _ y: Date) -> Double {
        let gap = abs(x.timeIntervalSince(y))
        if gap < 1 { return 1 }
        if gap > todoWindow { return 0 }
        return dayKey(x, timezone: a.timezone) == dayKey(y, timezone: b.timezone) ? 0.8 : 0.6
    }
}
