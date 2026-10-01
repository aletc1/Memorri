import Foundation

/// A busy desktop shows several windows at once. Once a calendar's grid is known, only the text inside it belongs to the calendar:
/// the text of the other windows would only make the model list things that are not in it (and take longer to answer).
public enum SubjectRegion {
    /// The lines inside the calendar's grid, with their own numbers. Everything is kept when no grid is known.
    public static func lines(_ lines: [RecognisedLine], kind: ScreenKind, headers: [DateHeader], cells: [DateHeader]) -> [RecognisedLine] {
        guard let region = region(kind: kind, headers: headers, cells: cells) else { return lines }
        return lines.filter { region.contains(x: $0.box.midX, y: $0.box.midY) }
    }

    struct Region: Equatable {
        let minX: Double, maxX: Double, minY: Double, maxY: Double
        func contains(x: Double, y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    static func region(kind: ScreenKind, headers: [DateHeader], cells: [DateHeader]) -> Region? {
        switch kind {
        case .calendarMonth:
            guard cells.count >= 7, let width = cells.first?.cellWidth, width > 0 else { return nil }
            let ys = Array(Set(cells.map(\.midY))).sorted()
            let gaps = zip(ys, ys.dropFirst()).map { $1 - $0 }.sorted()
            let rowHeight = gaps.isEmpty ? width * 0.6 : gaps[gaps.count / 2]
            return Region(minX: (cells.map(\.midX).min() ?? 0) - width / 2, maxX: (cells.map(\.midX).max() ?? 0) + width / 2,
                          minY: (ys.first ?? 0) - rowHeight * 0.2, maxY: (ys.last ?? 0) + rowHeight)
        case .calendarWeek:
            // Columns of a week view: from half a column left of the first header to half a column right of the last. The hour scale
            // at the side stays out (it is read for durations from all the lines, not from this list).
            guard headers.count >= 2 else { return nil }
            let xs = headers.map(\.midX).sorted()
            let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }.sorted()
            let column = gaps[gaps.count / 2]
            let top = headers.map(\.midY).min() ?? 0
            return Region(minX: xs[0] - column * 0.6, maxX: xs[xs.count - 1] + column * 0.6, minY: top - 1, maxY: .greatestFiniteMagnitude)
        case .calendarDay, .email, .chat, .document, .other:
            return nil
        }
    }
}
