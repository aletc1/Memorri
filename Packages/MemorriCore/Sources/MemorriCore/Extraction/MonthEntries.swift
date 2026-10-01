import Foundation

/// Reads the entries of a month view from the picture's lines and the grid of day cells, with no model call (ADR 0018). In a month
/// grid every entry is one line of text inside a cell, with its time at the right of the same row, so the model had nothing to add:
/// on a real month with 250 entries it took five minutes and returned 176 of them, and it dropped whole days. Reading the lines is
/// complete, exact (the title is the text as read) and instant.
enum MonthEntries {
    static let version = "geometry-calendar_month-v1"
    /// A month grid has at least four weeks of seven cells.
    static let minimumCells = 28

    private static let leadingNoise = CharacterSet(charactersIn: "|•·●○◯©®@*›>- ").union(.whitespaces)
    private static let leadingIcon = try! NSRegularExpression(pattern: #"^[oO0©@]\s+(?=\S)"#)
    private static let overflow = try! NSRegularExpression(pattern: #"^(?:y\s+\d+\s+m[aá]s|\+\s?\d+\s+(?:more|m[aá]s)|\d+\s+more|and\s+\d+\s+more)$"#, options: .caseInsensitive)
    private static let clockAtEnd = try! NSRegularExpression(pattern: #"\s*\b\d{1,2}:\d{2}(?:\s?[ap]\.?m\.?)?$"#, options: .caseInsensitive)
    private static let clockAtStart = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(?:\s?[ap]\.?m\.?)?\s*"#, options: .caseInsensitive)

    /// `lines` are the lines inside the grid (see `SubjectRegion`), `cells` the day cells. Lines that join the entries of two cells
    /// were already cut at their bars when the picture was read (`LineSplitter`).
    static func drafts(lines: [RecognisedLine], cells: [DateHeader], locales: [Locale]) -> [FindingDraft] {
        let labelLines = Set(cells.map(\.line))
        let candidates = lines.filter { line in
            !labelLines.contains(line.n) && !DateResolver.isClockLabel(line.text) && !DateResolver.isCellLabel(line.text, locales: locales)
        }
        var drafts: [FindingDraft] = []
        for line in candidates {
            do {
                let range = NSRange(line.text.startIndex..., in: line.text)
                if overflow.firstMatch(in: line.text, range: range) != nil { continue }
                var text = clean(line.text)
                var time: String?
                if let match = clockAtEnd.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let found = Range(match.range, in: text) {
                    time = String(text[found]).trimmingCharacters(in: .whitespaces); text.removeSubrange(found)
                } else if let match = clockAtStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let found = Range(match.range, in: text) {
                    time = String(text[found]).trimmingCharacters(in: .whitespaces); text.removeSubrange(found)
                }
                text = clean(text)
                guard text.filter(\.isLetter).count >= 2 else { continue }
                let clock = time ?? rowClock(for: line, in: lines, cells: cells)
                drafts.append(FindingDraft(kind: .appointment, title: text, citedLines: [line.n], startText: clock))
            }
        }
        return drafts
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: leadingNoise)
        if let match = leadingIcon.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)), let found = Range(match.range, in: result) {
            result.removeSubrange(found)
        }
        return result.trimmingCharacters(in: leadingNoise.union(CharacterSet(charactersIn: "|")))
    }

    /// The line that is only a time, on the entry's own row, to its right and inside its cell's column.
    private static func rowClock(for entry: RecognisedLine, in lines: [RecognisedLine], cells: [DateHeader]) -> String? {
        guard let cell = cells.first(where: { $0.cellWidth > 0 && entry.box.x >= Int($0.midX - $0.cellWidth / 2) - 2 && Double(entry.box.x) < $0.midX + $0.cellWidth / 2 })
        else { return nil }
        let left = cell.midX - cell.cellWidth / 2, right = cell.midX + cell.cellWidth / 2
        return lines.filter { line in
            DateResolver.isClockLabel(line.text) && line.box.x > entry.box.x && line.box.midX >= left && line.box.midX < right
                && abs(line.box.midY - entry.box.midY) <= max(4, Double(entry.box.height) * 0.6)
        }.min { $0.box.x < $1.box.x }?.text.trimmingCharacters(in: .whitespaces)
    }
}
