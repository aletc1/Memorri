import Foundation

/// A date shown in a header of a calendar view (`Mon 12`, `Wednesday, October 14, 2026`) and where it sits.
public struct DateHeader: Sendable, Equatable {
    public let line: Int
    public let midX: Double
    /// Only month views use it: the vertical centre of a day label.
    public let midY: Double
    /// Only month views use it: how wide the cell is (`midX` is then the cell's centre, not the label's).
    public let cellWidth: Double
    /// Year, month and day only.
    public let date: DateComponents
    /// True when nothing on the picture named the month (no title, no label with a month's name) and it was taken from the capture's
    /// date: the day numbers alone fit the same weekday grid in several months. Dates read from this header are only guesses.
    public let monthAssumed: Bool

    public init(line: Int, midX: Double, midY: Double = 0, cellWidth: Double = 0, date: DateComponents, monthAssumed: Bool = false) {
        self.line = line; self.midX = midX; self.midY = midY; self.cellWidth = cellWidth; self.date = date; self.monthAssumed = monthAssumed
    }
}

/// What a date text is resolved against: when and where the picture was taken, what its headers say, and how its numbers are ordered.
public struct ResolutionContext: Sendable {
    public let captureTime: Date
    public let timezone: TimeZone
    public let headers: [DateHeader]
    /// The day labels of a month view, each the header of the cell it sits in.
    public let cells: [DateHeader]
    public let lines: [RecognisedLine]
    public let dateOrder: DateOrder?
    public let locales: [Locale]
    /// When an email was sent: "tomorrow" in an email means tomorrow from then, not from the capture.
    public let sentReference: Date?

    public init(captureTime: Date, timezone: TimeZone, headers: [DateHeader] = [], lines: [RecognisedLine] = [], dateOrder: DateOrder? = nil,
                locales: [Locale], sentReference: Date? = nil, cells: [DateHeader] = []) {
        self.captureTime = captureTime; self.timezone = timezone; self.headers = headers; self.lines = lines; self.dateOrder = dateOrder
        self.locales = locales; self.sentReference = sentReference; self.cells = cells
    }

    var reference: Date { sentReference ?? captureTime }
}

/// A date or time field after resolution. `date` is nil when the text could not be settled; the text is then kept as written.
public struct ResolvedValue: Sendable, Equatable {
    public let date: Date?
    public let allDay: Bool
    public let provenance: FieldProvenance?
    public let unresolvedText: String?
}

/// Turns the literal date texts of a finding into instants, by rules applied in order, each recorded as the provenance
/// (research R6): `explicit-date`, `header-column`, `relative-day`, `end-of-week`, `weekday-only`, `time-only`,
/// `deadline-reminder`. What no rule settles stays as written.
public enum DateResolver {
    private struct Day: Hashable {
        var year: Int, month: Int, day: Int
    }

    private struct Base {
        let day: Day
        let rule: String
        let reason: String?
    }

    private static let none = ResolvedValue(date: nil, allDay: false, provenance: nil, unresolvedText: nil)

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }

    // MARK: Resolving one field

    /// A day number of one or two digits, alone or beside a month's name or abbreviation (`1`, `oct`, `1 oct`, `oct 1`).
    static func isCellLabel(_ text: String, locales: [Locale]) -> Bool {
        let digits = text.filter(\.isNumber), letters = text.filter { $0.isLetter }.lowercased()
        let rest = text.filter { !$0.isNumber && !$0.isLetter && !$0.isWhitespace && $0 != "." }
        guard rest.isEmpty, digits.count <= 2, !(digits.isEmpty && letters.isEmpty) else { return false }
        if letters.isEmpty { return true }
        guard letters.count >= 3 else { return false }
        return locales.contains { locale in
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            return (calendar.monthSymbols + calendar.shortMonthSymbols).contains {
                $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasPrefix(letters)
                    || letters.hasPrefix($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }
        }
    }

    /// `field` is `start`, `end`, `due` or `remind`. An empty `remind` text asks for the deadline reminder rule.
    public static func resolve(text: String, field: String, draft: FindingDraft, in context: ResolutionContext) -> ResolvedValue {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // In a month view a bare number is the label of the entry's cell (the model often gives it as the date), not a date.
        // The first of a month is often labelled with the month name too ("1 oct"), and the model may give just that.
        if !context.cells.isEmpty, isCellLabel(trimmed, locales: context.locales) { trimmed = "" }
        if trimmed.isEmpty {
            if field == "remind" { return deadlineReminder(draft, context) }
            // An all-day banner in a week view, or an entry without a time in a month cell, has no text of its own for its
            // day: the header above its column, or the label of its cell, gives it.
            // The model often puts the month's title in date_text; a text without a day does not date anything.
            let calendarEntry = (!context.cells.isEmpty || !context.headers.isEmpty) && draft.allDay != false
            if field == "start", draft.allDay == true || calendarEntry, draft.startText.map(isBlank) ?? true, !nameDay(draft.dateText, context),
               let header = headerDay(draft: draft, context: context), let date = makeDate(header.day, hour: nil, minute: nil, zone: context.timezone) {
                return ResolvedValue(date: date, allDay: true, provenance: FieldProvenance(origin: header.assumed ? .inferred : .read, rule: header.rule,
                                                                                          reason: header.assumed ? "month-assumed" : nil), unresolvedText: nil)
            }
            return none
        }
        let unresolved = ResolvedValue(date: nil, allDay: false, provenance: nil, unresolvedText: trimmed)
        guard let parsed = DateParser.parse(trimmed, locales: context.locales, order: context.dateOrder),
              let base = baseDay(parsed, field: field, draft: draft, context: context, allowFallback: true),
              let date = makeDate(base.day, hour: parsed.hour, minute: parsed.minute, zone: context.timezone) else { return unresolved }
        let reason = base.reason ?? (parsed.orderAssumed ? "date-order" : nil)
        let provenance = FieldProvenance(origin: reason == nil ? .read : .inferred, rule: base.rule, reason: reason)
        return ResolvedValue(date: date, allDay: parsed.hour == nil, provenance: provenance, unresolvedText: nil)
    }

    /// When an email was sent, from its own header text. `nil` when there is none or it is not a date.
    public static func sentReference(for draft: FindingDraft, in context: ResolutionContext) -> Date? {
        guard let text = draft.sentText,
              let parsed = DateParser.parse(text, locales: context.locales, order: context.dateOrder),
              let base = baseDay(parsed, field: "sent", draft: draft, context: context, allowFallback: false) else { return nil }
        return makeDate(base.day, hour: parsed.hour, minute: parsed.minute, zone: context.timezone)
    }

    // MARK: Which day

    private static func baseDay(_ parsed: ParsedDate, field: String, draft: FindingDraft, context: ResolutionContext, allowFallback: Bool) -> Base? {
        let zone = context.timezone
        let today = day(of: context.reference, zone: zone)
        let reasonForOrder = parsed.orderAssumed ? "date-order" : nil

        if let month = parsed.month, let dayNumber = parsed.day {
            let year = parsed.year ?? nearestYear(month: month, day: dayNumber, weekday: parsed.weekday, reference: today, zone: zone)
            let chosen = Day(year: year, month: month, day: dayNumber)
            return valid(chosen, zone: zone) ? Base(day: chosen, rule: "explicit-date", reason: reasonForOrder) : nil
        }
        if let relative = parsed.relative {
            switch relative {
            case .today: return Base(day: today, rule: "relative-day", reason: nil)
            case .tomorrow: return Base(day: adding(1, to: today, zone: zone), rule: "relative-day", reason: nil)
            case .yesterday: return Base(day: adding(-1, to: today, zone: zone), rule: "relative-day", reason: nil)
            case .inDays(let n): return Base(day: adding(n, to: today, zone: zone), rule: "relative-day", reason: nil)
            case .next(let weekday):
                let ahead = (weekday - isoWeekday(today, zone: zone) + 6) % 7 + 1      // 1...7: strictly after today
                return Base(day: adding(ahead, to: today, zone: zone), rule: "relative-day", reason: nil)
            case .endOfWeek:
                let current = isoWeekday(today, zone: zone)
                let ahead = current <= 5 ? 5 - current : 12 - current              // this Friday, or next Friday from the weekend
                return Base(day: adding(ahead, to: today, zone: zone), rule: "end-of-week", reason: nil)
            }
        }
        if let weekday = parsed.weekday {
            if let dayNumber = parsed.day {
                guard let chosen = nearestDay(weekday: weekday, day: dayNumber, reference: today, zone: zone) else { return nil }
                return Base(day: chosen, rule: "explicit-date", reason: nil)
            }
            let ahead = (weekday - isoWeekday(today, zone: zone) + 7) % 7          // 0...6: today counts
            return Base(day: adding(ahead, to: today, zone: zone), rule: "weekday-only", reason: nil)
        }

        // A time alone: the day comes from the picture's headers, else from the finding's other texts, else it is the reference day.
        guard allowFallback, parsed.hour != nil else { return nil }
        // A full date written next to the time beats the column it sits in; a header beats vaguer words.
        func written(_ text: String?) -> Base? {
            guard let text, let other = DateParser.parse(text, locales: context.locales, order: context.dateOrder), other.day != nil,
                  other.month != nil || other.weekday != nil else { return nil }
            return baseDay(other, field: field, draft: draft, context: context, allowFallback: false)
        }
        if let explicit = written(draft.dateText) ?? (field == "end" || field == "remind" ? written(draft.startText) : nil) { return explicit }
        if let header = headerDay(draft: draft, context: context) { return Base(day: header.day, rule: header.rule, reason: header.assumed ? "month-assumed" : nil) }
        var sources: [String?] = [draft.dateText]
        if field == "end" || field == "remind" { sources.append(draft.startText) }
        for source in sources {
            guard let source, let other = DateParser.parse(source, locales: context.locales, order: context.dateOrder),
                  other.month != nil || other.relative != nil || other.weekday != nil,
                  let base = baseDay(other, field: field, draft: draft, context: context, allowFallback: false) else { continue }
            return base
        }
        return Base(day: today, rule: "time-only", reason: nil)
    }

    private static let clockLabel = try! NSRegularExpression(pattern: #"^\d{1,2}(?::\d{2})?\s?(?:[ap]\.?m\.?)?$"#, options: .caseInsensitive)

    /// True for a line that is only a time, such as the labels of the hour scale (`15:00`, `3 PM`).
    static func isClockLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return clockLabel.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// True when the text names a day of its own: a month, a weekday or a relative word. A bare number is only a cell's label.
    private static func nameDay(_ text: String?, _ context: ResolutionContext) -> Bool {
        guard let text, !isBlank(text), let parsed = DateParser.parse(text, locales: context.locales, order: context.dateOrder) else { return false }
        return parsed.month != nil || parsed.weekday != nil || parsed.relative != nil
    }

    /// The header above the finding's column: the model's own `column_line` when it is a header, else the header whose
    /// horizontal centre is nearest to the centre of the first cited line. In a month view the headers are the day labels of
    /// the cells, and without the model's pick the nearest label above the line in its column is used.
    private static func headerDay(draft: FindingDraft, context: ResolutionContext) -> (day: Day, rule: String, assumed: Bool)? {
        func day(_ header: DateHeader) -> Day? {
            guard let y = header.date.year, let m = header.date.month, let d = header.date.day else { return nil }
            return Day(year: y, month: m, day: d)
        }
        // The line that places the entry: the first cited line that is not just a clock label of the hour scale.
        let cited = draft.citedLines.compactMap { n in context.lines.first { $0.n == n } }
        // In a month view the day label of the cell is often cited too ("oct" beside the 1st is one); it sits at the edge of its cell,
        // so it is not what places the entry.
        let labelLines = Set(context.cells.map(\.line))
        let first = cited.first { !isClockLabel($0.text) && !labelLines.contains($0.n) && (context.cells.isEmpty || !isCellLabel($0.text, locales: context.locales)) }
            ?? cited.first { !isClockLabel($0.text) } ?? cited.first
        if !context.cells.isEmpty {
            // The cell the line sits in decides the day; the model's pick is only used for a line that has no position.
            guard let line = first else {
                return draft.columnLine.flatMap { column in context.cells.first { $0.line == column } }.flatMap { cell in day(cell).map { ($0, "month-cell", cell.monthAssumed) } }
            }
            func distance(_ cell: DateHeader) -> Double {
                let sideways = abs(cell.midX - cell.cellWidth / 2 - Double(line.box.x))
                let upwards = line.box.midY - cell.midY
                return sideways * 3 + upwards
            }
            let nearest = context.cells.filter { $0.midY <= line.box.midY }.min { distance($0) < distance($1) }
            return nearest.flatMap { cell in day(cell).map { ($0, "month-cell", cell.monthAssumed) } }
        }
        let headers = context.headers
        guard !headers.isEmpty else { return nil }
        if let column = draft.columnLine, let header = headers.first(where: { $0.line == column }) { return day(header).map { ($0, "header-column", header.monthAssumed) } }
        if headers.count == 1 { return day(headers[0]).map { ($0, "header-column", headers[0].monthAssumed) } }
        guard let line = first else { return nil }
        return headers.min { abs($0.midX - line.box.midX) < abs($1.midX - line.box.midX) }.flatMap { header in day(header).map { ($0, "header-column", header.monthAssumed) } }
    }

    // MARK: Deadline reminder

    /// Words that only say "a date": a deadline titled with them has no action, so it gets no reminder.
    private static let genericWords: Set<String> = ["deadline", "due", "date", "by", "the", "fecha", "limite", "plazo", "vencimiento", "cutoff", "end",
                                                     "of", "de", "la", "el", "final", "dead", "line"]

    /// True unless the title only says "deadline" or "due date" in some way.
    public static func titleHasAction(_ title: String) -> Bool {
        let words = DateParser.fold(title).split { !$0.isLetter }.map(String.init)
        return words.contains { !genericWords.contains($0) }
    }

    /// 09:00 local time on the working day (Monday to Friday) before the due date, for a deadline with an action and no
    /// reminder text; flagged inferred.
    private static func deadlineReminder(_ draft: FindingDraft, _ context: ResolutionContext) -> ResolvedValue {
        guard draft.kind == .deadline, draft.remindText == nil, titleHasAction(draft.title), let dueText = draft.dueText else { return none }
        let due = resolve(text: dueText, field: "due", draft: draft, in: context)
        guard let dueDate = due.date else { return none }
        let zone = context.timezone
        var previous = adding(-1, to: day(of: dueDate, zone: zone), zone: zone)
        while isoWeekday(previous, zone: zone) > 5 { previous = adding(-1, to: previous, zone: zone) }
        guard let date = makeDate(previous, hour: 9, minute: 0, zone: zone) else { return none }
        return ResolvedValue(date: date, allDay: false, provenance: FieldProvenance(origin: .inferred, rule: "deadline-reminder", reason: nil),
                             unresolvedText: nil)
    }

    // MARK: Headers

    /// The date headers of a week or day view: lines with a weekday name and a day number and no time, such as `Mon 12`.
    /// The month and year come from the header itself, else from a title line with a month name (`October 12 – 16, 2026`),
    /// else from the weekday and day number closest to the reference.
    public static func headers(in lines: [RecognisedLine], locales: [Locale], reference: Date, timezone: TimeZone) -> [DateHeader] {
        let today = day(of: reference, zone: timezone)
        var hintMonth: Int?, hintYear: Int?
        var candidates: [(line: RecognisedLine, parsed: ParsedDate)] = []
        for line in lines + stackedHeaders(in: lines, locales: locales) {
            // A title that only names the month and year (`Febrero de 2026`) is not a date by itself but says which month the days are in.
            if hintMonth == nil, let title = monthTitle(line.text, locales: locales) { hintMonth = title.month; hintYear = title.year; continue }
            guard var parsed = DateParser.parse(line.text, locales: locales), parsed.hour == nil, parsed.relative == nil else { continue }
            // "mar 13" is March 13 in English and Tuesday 13 in Spanish; a header needs a weekday, so the other reading is tried too.
            if parsed.weekday == nil, locales.count > 1, let other = DateParser.parse(line.text, locales: Array(locales.reversed())),
               other.weekday != nil, other.day != nil, other.hour == nil { parsed = other }
            if parsed.weekday != nil, parsed.day != nil {
                candidates.append((line, parsed))
            } else if parsed.weekday == nil, let month = parsed.month, hintMonth == nil {
                hintMonth = month
                hintYear = parsed.year ?? DateParser.match(#"\b((?:19|20)\d{2})\b"#, in: line.text).flatMap { Int($0[1]) }
            }
        }
        let found: [DateHeader] = candidates.compactMap { item in
            guard let weekday = item.parsed.weekday, let dayNumber = item.parsed.day else { return nil }
            var chosen: Day?
            if let month = item.parsed.month, let year = item.parsed.year {
                chosen = Day(year: year, month: month, day: dayNumber)
            } else if let month = item.parsed.month {
                chosen = Day(year: nearestYear(month: month, day: dayNumber, weekday: weekday, reference: today, zone: timezone), month: month, day: dayNumber)
            } else if let month = hintMonth {
                // The title's month, else its neighbours: a week that starts in one month and ends in the next carries the title of one.
                for shift in [0, -1, 1] where chosen == nil {
                    var m = month + shift, y = hintYear ?? nearestYear(month: month, day: dayNumber, weekday: weekday, reference: today, zone: timezone)
                    if m < 1 { m += 12; y -= 1 } else if m > 12 { m -= 12; y += 1 }
                    let hinted = Day(year: y, month: m, day: dayNumber)
                    if valid(hinted, zone: timezone), isoWeekday(hinted, zone: timezone) == weekday { chosen = hinted }
                }
            }
            var assumed = false
            if chosen == nil || !valid(chosen!, zone: timezone) { chosen = nearestDay(weekday: weekday, day: dayNumber, reference: today, zone: timezone); assumed = true }
            guard let day = chosen, valid(day, zone: timezone) else { return nil }
            return DateHeader(line: item.line.n, midX: item.line.box.midX, midY: item.line.box.midY, date: DateComponents(year: day.year, month: day.month, day: day.day),
                              monthAssumed: assumed)
        }
        return filled(found.sorted { $0.midX < $1.midX }, zone: timezone)
    }

    /// A column whose header the reading missed (a highlighted "today" is the usual one) still gets its day: when two neighbouring
    /// headers are more than a day apart, the days between them are added at even spacing across the gap. They have no line.
    private static func filled(_ headers: [DateHeader], zone: TimeZone) -> [DateHeader] {
        guard headers.count >= 3 else { return headers }
        var result: [DateHeader] = []
        for (index, header) in headers.enumerated() {
            result.append(header)
            guard index + 1 < headers.count, let from = header.date.year.flatMap({ y in header.date.month.flatMap { m in header.date.day.map { Day(year: y, month: m, day: $0) } } }),
                  let toDay = headers[index + 1].date.year.flatMap({ y in headers[index + 1].date.month.flatMap { m in headers[index + 1].date.day.map { Day(year: y, month: m, day: $0) } } }),
                  let start = makeDate(from, hour: nil, minute: nil, zone: zone), let end = makeDate(toDay, hour: nil, minute: nil, zone: zone),
                  let days = calendar(zone).dateComponents([.day], from: start, to: end).day, days >= 2, days <= 6 else { continue }
            let gap = headers[index + 1].midX - header.midX
            for step in 1..<days {
                let date = adding(step, to: from, zone: zone)
                result.append(DateHeader(line: 0, midX: header.midX + gap * Double(step) / Double(days), midY: header.midY,
                                         date: DateComponents(year: date.year, month: date.month, day: date.day), monthAssumed: header.monthAssumed))
            }
        }
        return result
    }

    /// Some calendars write a header as two lines: the day number with the weekday name right under it (or over it). Each such
    /// pair becomes one line "Lunes 28" that keeps the number line's `n` and covers both boxes.
    static func stackedHeaders(in lines: [RecognisedLine], locales: [Locale]) -> [RecognisedLine] {
        let numbers = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return text.count <= 2 && (Int(text).map { (1...31).contains($0) } ?? false)
        }
        let names = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.count >= 3, text.allSatisfy({ $0.isLetter || $0 == "." }), let parsed = DateParser.parse(text, locales: locales) else { return false }
            return parsed.weekday != nil && parsed.day == nil && parsed.month == nil && parsed.hour == nil
        }
        var used = Set<Int>(), merged: [RecognisedLine] = []
        for number in numbers {
            let near = names.filter { name in
                let reach = Double(max(number.box.height, name.box.height)) * 2.5
                let sameColumn = abs(Double(name.box.x - number.box.x)) <= Double(max(number.box.width, name.box.width)) * 0.75
                return !used.contains(name.n) && sameColumn && abs(name.box.midY - number.box.midY) <= reach && name.box.midY != number.box.midY
            }
            guard let name = near.min(by: { abs($0.box.midY - number.box.midY) < abs($1.box.midY - number.box.midY) }) else { continue }
            used.insert(name.n)
            let x = min(number.box.x, name.box.x), y = min(number.box.y, name.box.y)
            let right = max(number.box.x + number.box.width, name.box.x + name.box.width), bottom = max(number.box.y + number.box.height, name.box.y + name.box.height)
            merged.append(RecognisedLine(n: number.n, text: "\(name.text) \(number.text.trimmingCharacters(in: .whitespaces))",
                                         box: PixelBox(x: x, y: y, width: right - x, height: bottom - y), confidence: min(number.confidence, name.confidence)))
        }
        return merged
    }

    // MARK: Month cells

    /// A line that only names a month, with or without a year (`Febrero de 2026`, `October 2026`, `octubre`): a month view's title.
    /// Any other word on the line makes it something else. The month is the first one named.
    static func monthTitle(_ text: String, locales: [Locale]) -> (month: Int, year: Int?)? {
        let months = Names.months(for: locales)
        var month: Int?, year: Int?
        let tokens = DateParser.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty, tokens.count <= 6 else { return nil }
        for token in tokens {
            if let number = months[token.replacingOccurrences(of: ".", with: "")] { if month == nil { month = number } }
            else if token.count == 4, let value = Int(token), (1990...2100).contains(value) { if year == nil { year = value } }
            else if ["de", "del", "of"].contains(token) { continue }
            else { return nil }
        }
        // A month's name alone (`oct`) is more likely the label of a cell than a title: without a year it takes the whole name.
        guard let month, year != nil || tokens.contains(where: { $0.count >= 5 || ["june", "july", "mayo"].contains($0) }) else { return nil }
        return (month, year)
    }

    /// The month of a cell label that carries one (`1 feb`): the first of a month is often labelled with its name.
    static func labelMonth(in lines: [RecognisedLine], locales: [Locale]) -> Int? {
        for line in lines where isCellLabel(line.text, locales: locales) && line.text.contains(where: \.isLetter) {
            if let parsed = DateParser.parse(line.text, locales: locales), parsed.weekday == nil, parsed.hour == nil, parsed.day == 1, let month = parsed.month { return month }
        }
        return nil
    }

    /// The cells of a month view, each with the date it shows. The day labels (lines that are only a number from 1 to 31) fix
    /// the grid; a label the reading missed still has its cell, because a cell's date follows from its place (row and column),
    /// and the dates come from the labels that were read, so the days before the 1st and after the last belong to the
    /// neighbouring months on their own. The month comes from a title line (`October 2026`), else from the capture.
    /// A cell has the line number of its label, or a negative number when no label was read. `[]` for fewer than seven labels.
    public static func monthCells(in lines: [RecognisedLine], locales: [Locale], reference: Date, timezone: TimeZone) -> [DateHeader] {
        let candidates = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return text.count <= 2 && text.allSatisfy(\.isNumber) && (Int(text).map { (1...31).contains($0) } ?? false)
        }
        guard candidates.count >= 7 else { return [] }

        // Other windows show numbers too (a clock, a page number): keep the labels that sit in columns shared with at least a third of
        // the most populated column's labels, which is where a calendar's day labels are.
        let kept = Self.labelsInCommonColumns(candidates)
        guard kept.count >= 7 else { return [] }
        let labels = kept

        func spacing(_ values: [Double]) -> Double? {
            let gaps = zip(values, values.dropFirst()).map { $1 - $0 }.filter { $0 > 1 }
            guard let smallest = gaps.min() else { return nil }
            let single = gaps.filter { $0 <= smallest * 1.5 }.sorted()
            return single[single.count / 2]
        }
        // Columns and rows, from the labels' centres.
        let xs = Array(Set(labels.map { ($0.box.midX / 4).rounded() * 4 })).sorted()
        let heights = labels.map(\.box.height).sorted()
        let sameRow = Double(max(1, heights[heights.count / 2]))
        var rowCentres: [Double] = []
        for y in labels.map(\.box.midY).sorted() {
            if let last = rowCentres.last, y - last <= sameRow { continue }
            rowCentres.append(y)
        }
        var columnCentres: [Double] = []
        for x in labels.map(\.box.midX).sorted() {
            if let last = columnCentres.last, x - last <= sameRow { continue }
            columnCentres.append(x)
        }
        guard let width = spacing(columnCentres) ?? spacing(xs), width > 0 else { return [] }
        let height = spacing(rowCentres) ?? width
        let minX = xs[0], minY = rowCentres[0]
        struct Placed { let line: RecognisedLine; let number: Int; let row: Int; let column: Int }
        let placed = labels.map { line in
            Placed(line: line, number: Int(line.text.trimmingCharacters(in: .whitespaces)) ?? 0,
                   row: Int(((line.box.midY - minY) / height).rounded()), column: Int(((line.box.midX - minX) / width).rounded()))
        }
        guard placed.allSatisfy({ (0...6).contains($0.column) }) else { return [] }

        // Where a label sits in its cell: the alignment whose edge varies least from one column to the next.
        func spread(_ anchor: (RecognisedLine) -> Double) -> Double {
            Dictionary(grouping: placed, by: \.column).values.reduce(0.0) { total, group in
                let values = group.map { anchor($0.line) }
                return total + (values.max() ?? 0) - (values.min() ?? 0)
            }
        }
        let offsets: [(Double, (RecognisedLine) -> Double)] = [
            (width / 2, { Double($0.box.x) }), (0, { $0.box.midX }), (-width / 2, { Double($0.box.x + $0.box.width) })]
        let offset = offsets.min { spread($0.1) < spread($1.1) }!
        var centreOfColumn: [Int: Double] = [:]
        for (column, group) in Dictionary(grouping: placed, by: \.column) {
            let anchors = group.map { offset.1($0.line) }.sorted()
            centreOfColumn[column] = anchors[anchors.count / 2] + offset.0
        }
        func columnCentre(_ column: Int) -> Double {
            centreOfColumn[column] ?? ((centreOfColumn.min { abs($0.key - column) < abs($1.key - column) }).map { $0.value + Double(column - $0.key) * width } ?? 0)
        }
        func rowCentre(_ row: Int) -> Double { minY + Double(row) * height }

        // The month shown: the title above the grid (`Febrero de 2026`), else the month a label names (`1 feb`), else the month of the
        // reference. Several lines may read as a title (a small calendar in a side bar): the one over the grid's columns, nearest above it, wins.
        let today = day(of: reference, zone: timezone)
        var month = today.month, year = today.year
        var assumed = true
        let gridLeft = columnCentre(0) - width / 2, gridRight = columnCentre(6) + width / 2
        let titles = lines.compactMap { line -> (line: RecognisedLine, month: Int, year: Int?)? in
            guard line.box.midY < rowCentre(0), let title = monthTitle(line.text, locales: locales) else { return nil }
            return (line, title.month, title.year)
        }
        func overGrid(_ line: RecognisedLine) -> Bool { line.box.midX >= gridLeft && line.box.midX <= gridRight }
        if let title = titles.min(by: { a, b in
            overGrid(a.line) != overGrid(b.line) ? overGrid(a.line) : a.line.box.midY > b.line.box.midY
        }) {
            month = title.month
            year = title.year ?? today.year
            assumed = false
        } else if let named = labelMonth(in: lines, locales: locales) {
            month = named
            assumed = false
        }

        // The date of the first cell: every label votes for the day that would put its number where it is, in the shown month
        // or a neighbouring one; ties go to the start nearest the 1st of the shown month.
        var votes: [Day: Int] = [:]
        for item in placed {
            for shift in -1...1 {
                var m = month + shift, y = year
                while m < 1 { m += 12; y -= 1 }
                while m > 12 { m -= 12; y += 1 }
                let label = Day(year: y, month: m, day: item.number)
                guard valid(label, zone: timezone) else { continue }
                votes[adding(-(item.row * 7 + item.column), to: label, zone: timezone), default: 0] += 1
            }
        }
        let firstOfMonth = noon(Day(year: year, month: month, day: 1), zone: timezone)
        guard let start = votes.max(by: { a, b in
            a.value != b.value ? a.value < b.value
                : abs(noon(a.key, zone: timezone).timeIntervalSince(firstOfMonth)) > abs(noon(b.key, zone: timezone).timeIntervalSince(firstOfMonth))
        })?.key else { return [] }

        let rows = (placed.map(\.row).max() ?? 0) + 1
        var byPlace: [Int: Placed] = [:]
        for item in placed { byPlace[item.row * 7 + item.column] = item }
        return (0..<rows * 7).map { index in
            let cell = adding(index, to: start, zone: timezone)
            let row = index / 7, column = index % 7
            return DateHeader(line: byPlace[index]?.line.n ?? -(index + 1), midX: columnCentre(column), midY: byPlace[index]?.line.box.midY ?? rowCentre(row),
                              cellWidth: width, date: DateComponents(year: cell.year, month: cell.month, day: cell.day), monthAssumed: assumed)
        }
    }

    /// The labels that sit in the day columns of a grid: columns (labels closer than a label's height apart share one) with at least
    /// two labels, evenly spaced. Numbers of other windows (a clock, a page count) form columns of their own, far from the grid or
    /// not evenly spaced with it, so the longest chain of columns at the usual spacing, counted in labels, is the calendar's.
    private static func labelsInCommonColumns(_ labels: [RecognisedLine]) -> [RecognisedLine] {
        let heights = labels.map(\.box.height).sorted()
        let tolerance = Double(max(8, heights[heights.count / 2]))
        var columns: [(centre: Double, members: [RecognisedLine])] = []
        for label in labels.sorted(by: { $0.box.midX < $1.box.midX }) {
            if let last = columns.last, label.box.midX - last.centre <= tolerance { columns[columns.count - 1].members.append(label) }
            else { columns.append((label.box.midX, [label])) }
        }
        columns = columns.filter { $0.members.count >= 2 }
        guard columns.count >= 2 else { return columns.flatMap(\.members) }
        let gaps = zip(columns, columns.dropFirst()).map { $1.centre - $0.centre }.sorted()
        let usual = gaps[gaps.count / 2]
        var best: [RecognisedLine] = []
        for start in columns.indices {
            var chain = columns[start].members, last = columns[start].centre
            for column in columns[(start + 1)...] {
                let gap = column.centre - last
                guard abs(gap - usual) <= usual * 0.25 else { break }
                chain += column.members; last = column.centre
            }
            if chain.count > best.count { best = chain }
        }
        return best
    }

    // MARK: Calendar arithmetic

    private static func day(of date: Date, zone: TimeZone) -> Day {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private static func valid(_ day: Day, zone: TimeZone) -> Bool {
        guard (1...12).contains(day.month), (1...31).contains(day.day) else { return false }
        guard let date = makeDate(day, hour: nil, minute: nil, zone: zone) else { return false }
        return self.day(of: date, zone: zone) == day
    }

    private static func makeDate(_ day: Day, hour: Int?, minute: Int?, zone: TimeZone) -> Date? {
        guard valid(day, hour: hour, minute: minute, zone: zone) else { return nil }
        return calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour ?? 0, minute: minute ?? 0))
    }

    private static func valid(_ day: Day, hour: Int?, minute: Int?, zone: TimeZone) -> Bool {
        guard (1...12).contains(day.month), (1...31).contains(day.day), (0...23).contains(hour ?? 0), (0...59).contains(minute ?? 0) else { return false }
        let probe = calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
        return probe.map { self.day(of: $0, zone: zone) == day } ?? false
    }

    private static func adding(_ days: Int, to day: Day, zone: TimeZone) -> Day {
        let noon = calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        return self.day(of: calendar(zone).date(byAdding: .day, value: days, to: noon) ?? noon, zone: zone)
    }

    /// 1 (Monday) to 7 (Sunday).
    private static func isoWeekday(_ day: Day, zone: TimeZone) -> Int {
        let noon = calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        let weekday = calendar(zone).component(.weekday, from: noon)        // 1 = Sunday
        return weekday == 1 ? 7 : weekday - 1
    }

    private static func noon(_ day: Day, zone: TimeZone) -> Date {
        calendar(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
    }

    /// The year that puts `month`/`day` closest to the reference (a date in January seen in December is next year's);
    /// with a weekday, the nearest year where that day is that weekday when there is one.
    private static func nearestYear(month: Int, day: Int, weekday: Int?, reference: Day, zone: TimeZone) -> Int {
        let ref = noon(reference, zone: zone)
        let options = (reference.year - 1...reference.year + 1).map { Day(year: $0, month: month, day: day) }.filter { valid($0, zone: zone) }
        let matching = weekday.map { w in options.filter { isoWeekday($0, zone: zone) == w } } ?? []
        let pool = matching.isEmpty ? options : matching
        return pool.min { abs(noon($0, zone: zone).timeIntervalSince(ref)) < abs(noon($1, zone: zone).timeIntervalSince(ref)) }?.year ?? reference.year
    }

    /// The day with this weekday and day number closest to the reference, looking six months either way.
    private static func nearestDay(weekday: Int, day: Int, reference: Day, zone: TimeZone) -> Day? {
        let ref = noon(reference, zone: zone)
        var best: Day?
        for offset in -6...6 {
            var month = reference.month + offset, year = reference.year
            while month < 1 { month += 12; year -= 1 }
            while month > 12 { month -= 12; year += 1 }
            let candidate = Day(year: year, month: month, day: day)
            guard valid(candidate, zone: zone), isoWeekday(candidate, zone: zone) == weekday else { continue }
            if best == nil || abs(noon(candidate, zone: zone).timeIntervalSince(ref)) < abs(noon(best!, zone: zone).timeIntervalSince(ref)) { best = candidate }
        }
        return best
    }
}
