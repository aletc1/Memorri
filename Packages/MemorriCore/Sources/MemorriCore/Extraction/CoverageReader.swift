import Foundation

/// Works out which stretches of time a captured week or day view showed (spec 010, research R1). Reads only what the analysis already has: the date
/// headers (the day columns), the visible parts of the window and the hour labels of the time axis. When any of it is uncertain the answer is nil,
/// and nothing can then be taken as evidence that a meeting is gone.
public enum CoverageReader {
    public static func read(kind: ScreenKind, headers: [DateHeader], lines: [RecognisedLine], visible: [PixelBox], zone: TimeZone, windowKey: String) -> CoverageDraft? {
        guard kind == .calendarWeek || kind == .calendarDay, !headers.isEmpty, !visible.isEmpty else { return nil }
        // A date that is only a guess says nothing about which day the column is.
        guard headers.allSatisfy({ !$0.monthAssumed && !$0.monthConflict }) else { return nil }
        let sorted = headers.sorted { $0.midX < $1.midX }
        guard let axis = timeAxis(lines: lines, firstColumnX: sorted[0].midX, visible: visible) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var spans: [DateInterval] = []
        var seen: Set<DateComponents> = []
        for header in sorted {
            guard seen.insert(header.date).inserted, let day = calendar.date(from: header.date) else { continue }
            // The whole stretch of the column between the first and the last hour label must be in the visible part.
            let points = [axis.firstY, (axis.firstY + axis.lastY) / 2, axis.lastY].map { (header.midX, $0) }
            guard points.allSatisfy({ point in visible.contains { contains($0, point) } }) else { continue }
            guard let from = calendar.date(bySettingHour: axis.firstHour, minute: 0, second: 0, of: day),
                  let to = calendar.date(bySettingHour: axis.lastHour, minute: 0, second: 0, of: day), to > from else { continue }
            spans.append(DateInterval(start: from, end: to))
        }
        return spans.isEmpty ? nil : CoverageDraft(windowKey: windowKey, kind: kind, spans: spans)
    }

    private static func contains(_ box: PixelBox, _ point: (Double, Double)) -> Bool {
        point.0 >= Double(box.x) && point.0 <= Double(box.x + box.width) && point.1 >= Double(box.y) && point.1 <= Double(box.y + box.height)
    }

    // MARK: The time axis

    struct Axis { let firstHour: Int; let lastHour: Int; let firstY: Double; let lastY: Double }

    private struct Label { let value: Int; let suffix: Suffix?; let line: RecognisedLine }
    private enum Suffix { case am, pm }

    /// The hour labels in the left margin: at least three, in one column left of the first day, evenly spaced for their hours and increasing downwards,
    /// all inside the visible part.
    static func timeAxis(lines: [RecognisedLine], firstColumnX: Double, visible: [PixelBox]) -> Axis? {
        let labels = lines.compactMap { line -> Label? in parse(line.text).map { Label(value: $0.0, suffix: $0.1, line: line) } }
            .filter { Double($0.line.box.x + $0.line.box.width) <= firstColumnX }
        // The largest group whose left edges agree: the axis, and not a number elsewhere.
        var best: [Label] = []
        for anchor in labels {
            let group = labels.filter { abs($0.line.box.x - anchor.line.box.x) <= 25 }
            if group.count > best.count { best = group }
        }
        guard best.count >= 3 else { return nil }
        let column = best.sorted { $0.line.box.midY < $1.line.box.midY }
        guard let hours = unwrapped(column) else { return nil }
        let ys = column.map { $0.line.box.midY }
        let spanHours = Double(hours.last! - hours.first!)
        guard spanHours >= 2 else { return nil }
        let perHour = (ys.last! - ys.first!) / spanHours
        guard perHour > 0 else { return nil }
        for (hour, y) in zip(hours, ys) {
            guard abs(y - (ys.first! + Double(hour - hours.first!) * perHour)) <= perHour * 0.2 else { return nil }
        }
        for label in [column.first!, column.last!] {
            let centre = (Double(label.line.box.midX), label.line.box.midY)
            guard visible.contains(where: { contains($0, centre) }) else { return nil }
        }
        guard hours.last! <= 23 else { return nil }
        return Axis(firstHour: hours.first!, lastHour: hours.last!, firstY: ys.first!, lastY: ys.last!)
    }

    /// The hour of each label (0 to 23), increasing; nil when they cannot be read as increasing hours.
    private static func unwrapped(_ labels: [Label]) -> [Int]? {
        var hours: [Int] = []
        for label in labels {
            var hour: Int
            switch label.suffix {
            case .am?: hour = label.value % 12
            case .pm?: hour = label.value % 12 + 12
            case nil:
                hour = label.value
                // Bare numbers (`11`, `12`, `1`) count up through noon: add twelve until the hour grows.
                if let previous = hours.last, label.value <= 12 { while hour <= previous { hour += 12 } }
            }
            if let previous = hours.last, hour <= previous { return nil }
            hours.append(hour)
        }
        return hours
    }

    /// `9 AM`, `9:00`, `09:00`, `12 pm`, `13` as (number, suffix); the minutes must be zero.
    private static func parse(_ text: String) -> (Int, Suffix?)? {
        let cleaned = text.lowercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        guard let match = cleaned.wholeMatch(of: /(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?/) else { return nil }
        guard let value = Int(match.1), value <= 24 else { return nil }
        if let minutes = match.2, Int(minutes) != 0 { return nil }
        let suffix: Suffix? = match.3.map { $0.hasPrefix("a") ? .am : .pm }
        if suffix != nil, value < 1 || value > 12 { return nil }
        return (value, suffix)
    }
}
