import Foundation

/// The order the parts of a numeric date come in.
public enum DateOrder: String, Sendable, Equatable, Codable {
    case dmy, mdy, ymd

    /// The usual order of a locale: month first in the United States, year first where the region says so, day first elsewhere.
    static func usual(for locale: Locale?) -> DateOrder {
        switch locale?.region?.identifier {
        case "US", "PH": return .mdy
        case "JP", "CN", "KR", "TW", "HU", "LT": return .ymd
        default: return .dmy
        }
    }
}

/// The parts of a date or time as a picture wrote it. Nothing here is a date yet: the resolver adds the reference day.
public struct ParsedDate: Sendable, Equatable {
    public enum Relative: Sendable, Equatable {
        case today, tomorrow, yesterday
        case inDays(Int)
        /// "next Monday": the first such weekday after the reference day. `weekday` is 1 (Monday) to 7 (Sunday).
        case next(weekday: Int)
        /// The Friday of the reference week.
        case endOfWeek
    }

    /// 1 (Monday) to 7 (Sunday).
    public var weekday: Int?
    public var day: Int?
    public var month: Int?
    public var year: Int?
    public var hour: Int?
    public var minute: Int?
    public var relative: Relative?
    /// True when a numeric date was ambiguous (`03/04`) and the order was taken from a default or from other dates.
    public var orderAssumed: Bool

    public init(weekday: Int? = nil, day: Int? = nil, month: Int? = nil, year: Int? = nil, hour: Int? = nil, minute: Int? = nil,
                relative: Relative? = nil, orderAssumed: Bool = false) {
        self.weekday = weekday; self.day = day; self.month = month; self.year = year; self.hour = hour; self.minute = minute
        self.relative = relative; self.orderAssumed = orderAssumed
    }

    public var hasDatePart: Bool { day != nil || month != nil || year != nil }
    public var hasTime: Bool { hour != nil }
}

/// Reads literal date and time texts in English and Spanish first and in any other language the locales give names for.
/// The same text always gives the same parts (research R6).
public enum DateParser {
    public static func parse(_ text: String, locales: [Locale], order: DateOrder? = nil) -> ParsedDate? {
        var scanner = Scanner(text: text, locales: locales, order: order)
        return scanner.run()
    }

    /// The order shown by numeric dates that can only be read one way (`14/10` is day first, `10/14` month first,
    /// `2026-10-14` year first). `nil` when there are none or they disagree.
    public static func dateOrder(ofUnambiguous texts: [String]) -> DateOrder? {
        var votes: [DateOrder: Int] = [:]
        for text in texts {
            guard let found = numericDate(in: fold(text)) else { continue }
            if let vote = found.unambiguousOrder { votes[vote, default: 0] += 1 }
        }
        let ranked = votes.sorted { $0.value > $1.value }
        guard let first = ranked.first else { return nil }
        // A clear winner, or no disagreement at all; a tie means the picture does not say.
        return ranked.count == 1 || first.value > ranked[1].value ? first.key : nil
    }

    // MARK: Text handling

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    struct Numeric {
        let first: Int, second: Int, third: Int?
        let yearFirst: Bool
        var unambiguousOrder: DateOrder? {
            if yearFirst { return .ymd }
            if first > 12 && second <= 12 { return .dmy }
            if second > 12 && first <= 12 { return .mdy }
            return nil
        }
    }

    static func numericDate(in folded: String) -> Numeric? {
        if let m = match(#"(?<![\d:])(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?![\d:])"#, in: folded) {
            return Numeric(first: int(m[1]), second: int(m[2]), third: int(m[3]), yearFirst: true)
        }
        if let m = match(#"(?<![\d:/.\-])(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})(?![\d:])"#, in: folded) {
            return Numeric(first: int(m[1]), second: int(m[2]), third: int(m[3]), yearFirst: false)
        }
        if let m = match(#"(?<![\d:/.\-])(\d{1,2})[/\-](\d{1,2})(?![\d:/\-.])"#, in: folded) {
            return Numeric(first: int(m[1]), second: int(m[2]), third: nil, yearFirst: false)
        }
        return nil
    }

    static func int(_ text: String) -> Int { Int(text) ?? 0 }

    /// The captured groups of the first match (group 0 is the whole match), or nil.
    static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    // MARK: The scan

    private struct Scanner {
        var working: String
        let locales: [Locale]
        let order: DateOrder?
        var result = ParsedDate()
        var found = false

        init(text: String, locales: [Locale], order: DateOrder?) {
            self.working = DateParser.fold(text)
            self.locales = locales
            self.order = order
        }

        // Names (folded) for months 1...12 and weekdays 1...7 (Monday first).
        private var months: [String: Int] { Names.months(for: locales) }
        private var weekdays: [String: Int] { Names.weekdays(for: locales) }

        private static func alternation(_ names: [String]) -> String {
            names.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        }

        /// Finds the first match, blanks it out of the working text and returns its groups.
        private mutating func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let hit = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
                  let whole = Range(hit.range, in: working) else { return nil }
            let groups = (0..<hit.numberOfRanges).map { index in Range(hit.range(at: index), in: working).map { String(working[$0]) } ?? "" }
            working.replaceSubrange(whole, with: String(repeating: " ", count: working.distance(from: whole.lowerBound, to: whole.upperBound)))
            return groups
        }

        mutating func run() -> ParsedDate? {
            relative()
            time()
            dates()
            weekdayAndDay()
            return found ? result : nil
        }

        // Relative words
        private mutating func relative() {
            let weekdayNames = Self.alternation(Array(weekdays.keys))
            if let g = take(#"\b(?:next|proximo|proxima)\s+("# + weekdayNames + #")\b"#), let wd = weekdays[g[1]] {
                result.relative = .next(weekday: wd); found = true; return
            }
            if let g = take(#"\b("# + weekdayNames + #")\s+que\s+viene\b"#), let wd = weekdays[g[1]] {
                result.relative = .next(weekday: wd); found = true; return
            }
            if take(#"\b(?:end of (?:the )?week|fin de (?:la )?semana)\b"#) != nil { result.relative = .endOfWeek; found = true; return }
            if let g = take(#"\b(?:in|en)\s+(\d{1,3})\s+(?:days?|dias?)\b"#) { result.relative = .inDays(DateParser.int(g[1])); found = true; return }
            if take(#"\b(?:today|hoy)\b"#) != nil { result.relative = .today; found = true; return }
            if take(#"\b(?:tomorrow)\b"#) != nil || take(#"(?<!la )(?<!por la )\bmanana\b"#) != nil { result.relative = .tomorrow; found = true; return }
            if take(#"\b(?:yesterday|ayer)\b"#) != nil { result.relative = .yesterday; found = true; return }
        }

        // Clock times
        private mutating func time() {
            var hour: Int?, minute = 0, meridiem = ""
            if let g = take(#"(?<![\d:])(\d{1,2}):(\d{2})(?::\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?(?![\d:])"#) {
                hour = DateParser.int(g[1]); minute = DateParser.int(g[2]); meridiem = g[3]
            } else if let g = take(#"\b(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])"#) {
                hour = DateParser.int(g[1]); meridiem = g[2]
            } else if let g = take(#"\b(\d{1,2})h(\d{2})?\b"#) {
                hour = DateParser.int(g[1]); minute = g[2].isEmpty ? 0 : DateParser.int(g[2])
            }
            guard var h = hour, h <= 23, minute <= 59 else { return }
            let m = meridiem.replacingOccurrences(of: ".", with: "")
            if m == "pm", h < 12 { h += 12 }
            if m == "am", h == 12 { h = 0 }
            if (m == "am" || m == "pm") && hour! > 12 { return }
            result.hour = h; result.minute = minute; found = true
        }

        // Dates: numeric and with month names
        private mutating func dates() {
            let monthNames = Self.alternation(Array(months.keys))
            if let date = DateParser.numericDate(in: working) {
                apply(date)
                return
            }
            if let g = take(#"\b(\d{1,2})(?:st|nd|rd|th|o)?\s*(?:de\s+|of\s+)?("# + monthNames + #")\b\.?(?:\s*(?:de\s+|,\s*)?(\d{4}))?"#),
               let month = months[g[2]] {
                result.day = DateParser.int(g[1]); result.month = month; if !g[3].isEmpty { result.year = DateParser.int(g[3]) }
                found = true; return
            }
            if let g = take(#"\b("# + monthNames + #")\b\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:\s*,?\s*(\d{4}))?"#), let month = months[g[1]] {
                result.day = DateParser.int(g[2]); result.month = month; if !g[3].isEmpty { result.year = DateParser.int(g[3]) }
                found = true; return
            }
        }

        private mutating func apply(_ date: Numeric) {
            // Blank the matched text so the digits are not read again.
            _ = take(#"(?<![\d:/.\-])\d{1,4}[/.\-]\d{1,2}(?:[/.\-]\d{2,4})?(?![\d:])"#)
            func year(_ value: Int) -> Int { value < 100 ? 2000 + value : value }
            let chosen: DateOrder
            if date.yearFirst { chosen = .ymd }
            else if let sure = date.unambiguousOrder { chosen = sure }
            else { chosen = order ?? DateOrder.usual(for: locales.first); result.orderAssumed = true }
            switch chosen {
            case .ymd:
                result.year = year(date.first); result.month = date.second; result.day = date.third
            case .dmy:
                result.day = date.first; result.month = date.second; result.year = date.third.map(year)
            case .mdy:
                result.month = date.first; result.day = date.second; result.year = date.third.map(year)
            }
            guard let month = result.month, let day = result.day, (1...12).contains(month), (1...31).contains(day) else {
                result.day = nil; result.month = nil; result.year = nil; result.orderAssumed = false
                return
            }
            found = true
        }

        // A weekday name, alone or with the day number after it ("Wed 14")
        private mutating func weekdayAndDay() {
            let names = Self.alternation(Array(weekdays.keys))
            guard let g = take(#"\b("# + names + #")\b\.?(?:,?\s*(?:(?:el|the|on)\s+)?(\d{1,2})(?:st|nd|rd|th)?\b(?!\s*[:/\-]))?"#),
                  let wd = weekdays[g[1]] else { return }
            result.weekday = wd
            if !g[2].isEmpty, result.day == nil, (1...31).contains(DateParser.int(g[2])) { result.day = DateParser.int(g[2]) }
            found = true
        }
    }
}

/// Month and weekday names, folded to lower case without accents: English and Spanish first, then whatever the locales' own
/// symbols add (full and short). "mar" is March unless the first locale is Spanish, where it is Tuesday.
enum Names {
    private static let englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let spanishMonths = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    private static let englishWeekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let spanishWeekdays = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]

    private static func strip(_ name: String) -> String {
        DateParser.fold(name).replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func months(for locales: [Locale]) -> [String: Int] {
        var table: [String: Int] = [:]
        func add(_ name: String, _ number: Int) { let key = strip(name); if key.count >= 3, table[key] == nil { table[key] = number } }
        for (i, name) in englishMonths.enumerated() { add(name, i + 1); add(String(name.prefix(3)), i + 1) }
        for (i, name) in spanishMonths.enumerated() { add(name, i + 1); add(String(name.prefix(3)), i + 1) }
        add("sept", 9); add("setiembre", 9); add("dic", 12)
        for locale in locales {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            for (i, name) in calendar.monthSymbols.enumerated() { add(name, i + 1) }
            for (i, name) in calendar.shortMonthSymbols.enumerated() { add(name, i + 1) }
        }
        if locales.first?.language.languageCode?.identifier == "es" { table["mar"] = nil }
        return table
    }

    static func weekdays(for locales: [Locale]) -> [String: Int] {
        var table: [String: Int] = [:]
        func add(_ name: String, _ number: Int) { let key = strip(name); if key.count >= 3, table[key] == nil { table[key] = number } }
        for (i, name) in englishWeekdays.enumerated() { add(name, i + 1); add(String(name.prefix(3)), i + 1) }
        for (i, name) in spanishWeekdays.enumerated() { add(name, i + 1); add(String(name.prefix(3)), i + 1) }
        add("tues", 2); add("weds", 3); add("thur", 4); add("thurs", 4)
        for locale in locales {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            // Calendar symbols start on Sunday.
            for (i, name) in calendar.weekdaySymbols.enumerated() { add(name, i == 0 ? 7 : i) }
            for (i, name) in calendar.shortWeekdaySymbols.enumerated() { add(name, i == 0 ? 7 : i) }
        }
        if locales.first?.language.languageCode?.identifier != "es" { table["mar"] = nil }
        return table
    }
}
