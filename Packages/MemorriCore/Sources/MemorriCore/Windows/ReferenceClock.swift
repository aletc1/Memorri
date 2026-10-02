import Foundation

/// The moment that "today", "tomorrow" and weekdays in a window are relative to (spec 011, research R4).
public struct ReferenceClock: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// A clock inside the window's own surroundings (a remote desktop's taskbar).
        case windowClock = "window-clock"
        /// The clock of the screen's menu bar.
        case screenClock = "screen-clock"
        /// No clock was read: the time the picture was captured.
        case capture
        /// A clock was read but is more than a day from the capture time, so it is not trusted.
        case captureFarClock = "capture-far-clock"
    }

    /// A clock more than this far from the capture time is not believed.
    public static let farLimit: TimeInterval = 24 * 3600
    /// The strip of a remote window (at its top and at its bottom) and of the screen (at the top) where a clock is looked for.
    static let windowStrip = 0.06
    static let screenStrip = 0.03

    public let instant: Date
    public let source: Source
    /// True when the dates that depend on this reference are guesses: a clock was seen and not believed, or windows are known and none showed a clock.
    public let isGuess: Bool

    public init(instant: Date, source: Source, isGuess: Bool? = nil) {
        self.instant = instant; self.source = source; self.isGuess = isGuess ?? (source == .captureFarClock)
    }

    /// The clock for the dates of `window`: the one in its own surroundings when it is a remote desktop (`remote`), else the screen's menu bar
    /// clock, else the capture time. A clock without a date takes the capture's date in `timezone`; a clock more than a day from the capture
    /// time is ignored (the capture time is used, and the dates that depend on it are guesses). With no clock at all the capture time is used and,
    /// when the capture has windows, the dates that depend on it are guesses; a capture read as one window keeps today's behaviour (no flag).
    /// A window capture (`windowOnly`, spec 013) is a picture of one window and has no menu bar: only the window's own surroundings are searched, and
    /// with no clock the capture time is used without a flag, because a missing clock is what that picture looks like.
    public static func find(window: VisibleWindow?, remote: Bool, screen: VisibleScreen, captureTime: Date, timezone: TimeZone, pictureHeight: Int,
                            locales: [Locale], windowOnly: Bool = false) -> ReferenceClock {
        var sources: [(Source, [RecognisedLine])] = []
        if remote, let window {
            let height = Double(window.frame.height) * windowStrip
            let top = Double(window.frame.y), bottom = Double(window.frame.y + window.frame.height)
            sources.append((.windowClock, window.lines.filter { $0.box.midY <= top + height || $0.box.midY >= bottom - height }))
        }
        if !windowOnly {
            let limit = Double(pictureHeight) * screenStrip
            let menuBar = screen.perWindow ? screen.desktopLines : screen.windows.flatMap(\.lines)
            sources.append((.screenClock, menuBar.filter { $0.box.midY <= limit }))
        }
        for (source, lines) in sources {
            guard let instant = clock(in: lines, captureTime: captureTime, timezone: timezone, locales: locales) else { continue }
            if abs(instant.timeIntervalSince(captureTime)) > farLimit { return ReferenceClock(instant: captureTime, source: .captureFarClock) }
            return ReferenceClock(instant: instant, source: source)
        }
        return ReferenceClock(instant: captureTime, source: .capture, isGuess: screen.perWindow && !windowOnly)
    }

    // MARK: Reading a clock

    private static let timeOnly = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(?::\d{2})?\s?(?:[ap]\.?m\.?)?$"#, options: .caseInsensitive)

    private static func clock(in lines: [RecognisedLine], captureTime: Date, timezone: TimeZone, locales: [Locale]) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let ordered = lines.sorted { ($0.box.midY, $0.box.x) < ($1.box.midY, $1.box.x) }
        // A date with a time on one line (`Thu 1 Oct 20:31`, `Thu 10/1/2026 11:01 AM`).
        for line in ordered {
            guard let parsed = DateParser.parse(line.text, locales: locales), parsed.hour != nil, parsed.relative == nil else { continue }
            if let date = instant(parsed, captureTime: captureTime, calendar: calendar) { return date }
        }
        // A time on its own line with the date on the line right above or below it (a taskbar's two lines), else the capture's date.
        for line in ordered where isTime(line.text) {
            guard let time = DateParser.parse(line.text, locales: locales), let hour = time.hour else { continue }
            let neighbour = ordered.first { other in
                other.n != line.n && abs(other.box.midY - line.box.midY) <= Double(max(line.box.height, other.box.height)) * 2.2
                    && other.box.midX >= Double(line.box.x) - Double(line.box.width) && other.box.midX <= Double(line.box.x + 2 * line.box.width)
                    && DateParser.parse(other.text, locales: locales).map { $0.hour == nil && $0.relative == nil && ($0.day != nil) && ($0.month != nil || $0.weekday != nil) } == true
            }
            var parsed = ParsedDate(hour: hour, minute: time.minute ?? 0)
            if let neighbour, let date = DateParser.parse(neighbour.text, locales: locales) {
                parsed.weekday = date.weekday; parsed.day = date.day; parsed.month = date.month; parsed.year = date.year
            }
            if let date = instant(parsed, captureTime: captureTime, calendar: calendar) { return date }
        }
        return nil
    }

    private static func isTime(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return timeOnly.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// The instant a parsed clock shows, read in `calendar`'s zone. Without a day it is the capture's date; without a year the year that puts the
    /// date closest to the capture (and on the written weekday, when there is one).
    private static func instant(_ parsed: ParsedDate, captureTime: Date, calendar: Calendar) -> Date? {
        guard let hour = parsed.hour, (0...23).contains(hour), (0...59).contains(parsed.minute ?? 0) else { return nil }
        let today = calendar.dateComponents([.year, .month, .day], from: captureTime)
        var components = DateComponents(year: parsed.year ?? today.year, month: parsed.month ?? today.month, day: parsed.day ?? today.day, hour: hour, minute: parsed.minute ?? 0)
        if parsed.day == nil { components.month = today.month; components.year = today.year }
        else if parsed.month == nil {
            // A weekday and a day number without a month: the month (of the capture or its neighbours) where the weekday fits.
            guard let weekday = parsed.weekday else { return nil }
            for shift in [0, -1, 1] {
                var candidate = components
                var month = (today.month ?? 1) + shift, year = today.year ?? 2026
                if month < 1 { month += 12; year -= 1 } else if month > 12 { month -= 12; year += 1 }
                candidate.month = month; candidate.year = year
                if let date = calendar.date(from: candidate), calendar.component(.day, from: date) == parsed.day, isoWeekday(date, calendar) == weekday { return date }
            }
            return nil
        }
        if parsed.year == nil, parsed.day != nil {
            let years = [(today.year ?? 2026) - 1, today.year ?? 2026, (today.year ?? 2026) + 1].compactMap { year -> Date? in
                var candidate = components; candidate.year = year
                guard let date = calendar.date(from: candidate), calendar.component(.day, from: date) == parsed.day,
                      parsed.weekday.map({ isoWeekday(date, calendar) == $0 }) ?? true else { return nil }
                return date
            }
            return years.min { abs($0.timeIntervalSince(captureTime)) < abs($1.timeIntervalSince(captureTime)) }
        }
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == components.day else { return nil }
        return date
    }

    private static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        let sunday1 = calendar.component(.weekday, from: date)
        return sunday1 == 1 ? 7 : sunday1 - 1
    }
}
