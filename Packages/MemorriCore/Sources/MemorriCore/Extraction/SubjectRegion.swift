import Foundation

/// A busy desktop shows several windows at once. Once a calendar's grid is known, only the text inside it belongs to the calendar:
/// the text of the other windows would only make the model list things that are not in it (and take longer to answer).
public enum SubjectRegion {
    /// The lines inside the calendar's grid, with their own numbers. Everything is kept when no grid is known.
    /// With `windows` that carry their stack order, the text of a window drawn over the calendar (a dialog, a file list) is left out
    /// too: the calendar's window is the frontmost one that holds the first header or cell (that header is visible, so nothing covers
    /// it), and every window in front of it covers part of it. Windows without a stack order are not used.
    public static func lines(_ lines: [RecognisedLine], kind: ScreenKind, headers: [DateHeader], cells: [DateHeader],
                             windows: [WindowInfo] = []) -> [RecognisedLine] {
        guard let region = region(kind: kind, headers: headers, cells: cells) else { return lines }
        let inside = lines.filter { region.contains(x: $0.box.midX, y: $0.box.midY) }
        let anchor = kind == .calendarMonth ? cells.first.map { ($0.midX, $0.midY) } : headers.first.map { ($0.midX, $0.midY) }
        guard let anchor, windows.allSatisfy({ $0.stack != nil }), windows.count > 1 else { return inside }
        func contains(_ frame: PixelBox, _ x: Double, _ y: Double) -> Bool {
            x >= Double(frame.x) && x <= Double(frame.x + frame.width) && y >= Double(frame.y) && y <= Double(frame.y + frame.height)
        }
        guard let subject = windows.filter({ contains($0.frame, anchor.0, anchor.1) }).min(by: { ($0.stack ?? 0) < ($1.stack ?? 0) }) else { return inside }
        let inFront = windows.filter { ($0.stack ?? 0) < (subject.stack ?? 0) }
        return inside.filter { line in !inFront.contains { contains($0.frame, line.box.midX, line.box.midY) } }
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
            // A header written as a day number over a weekday name is one box, so the number's line starts a little above its middle.
            let top = headers.map(\.midY).min() ?? 0
            return Region(minX: xs[0] - column * 0.6, maxX: xs[xs.count - 1] + column * 0.6, minY: top - column * 0.2, maxY: .greatestFiniteMagnitude)
        case .calendarDay, .email, .chat, .document, .other:
            return nil
        }
    }
}
