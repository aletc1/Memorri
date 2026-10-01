import Foundation
import Testing
@testable import MemorriCore

@Suite struct MonthEntriesTests {
    private let es = [Locale(identifier: "es_ES"), Locale(identifier: "en_US")]

    /// Cells of 200 x 150 starting at (0, 60); the cell of column `c` spans x in c*200 ..< (c+1)*200. Labels use line numbers 1...n.
    private func cells() -> [DateHeader] {
        (0..<35).map { i in
            DateHeader(line: i + 1, midX: Double((i % 7) * 200 + 100), midY: Double(60 + (i / 7) * 150 + 9), cellWidth: 200,
                       date: DateComponents(year: 2026, month: 9, day: 28 + i))
        }
    }

    private func line(_ n: Int, _ text: String, x: Int, y: Int, w: Int = 120) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: 14), confidence: 0.9)
    }

    private func drafts(_ lines: [RecognisedLine]) -> [FindingDraft] { MonthEntries.drafts(lines: lines, cells: cells(), locales: es) }

    @Test func eachTextLineInACellIsAnAppointmentWithItsTimeFromItsRow() {
        let found = drafts([line(40, "| Daily standup", x: 10, y: 100), line(41, "12:00", x: 150, y: 102, w: 32),
                            line(42, "• Water the plants", x: 10, y: 120), line(43, "20:00", x: 150, y: 122, w: 32)])
        #expect(found.map(\.title) == ["Daily standup", "Water the plants"])
        #expect(found.map(\.startText) == ["12:00", "20:00"])
        #expect(found.allSatisfy { $0.kind == .appointment && $0.citedLines.count == 1 })
    }

    @Test func aTimeAtTheEndOrTheStartOfTheLineIsTakenOutOfTheTitle() {
        let found = drafts([line(40, "| Quarterly planning fo... 10:00", x: 10, y: 100, w: 190), line(41, "09:30 Budget review", x: 210, y: 100)])
        #expect(found.map(\.title) == ["Quarterly planning fo...", "Budget review"] && found.map(\.startText) == ["10:00", "09:30"])
    }

    @Test func anEntryWithNoTimeOnItsRowHasNone() {
        let found = drafts([line(40, "© Fiesta Nacional", x: 10, y: 100), line(41, "12:00", x: 150, y: 140, w: 32)])
        #expect(found.map(\.title) == ["Fiesta Nacional"] && found.map(\.startText) == [nil])
    }

    @Test func aTimeInTheNeighbouringCellIsNotTheEntrysTime() {
        // The time at x 250 belongs to the cell at the right (its entry starts at x 210), not to the entry in the first cell.
        let found = drafts([line(40, "Lunch", x: 10, y: 100, w: 60), line(41, "Dentist", x: 210, y: 100, w: 60), line(42, "13:30", x: 350, y: 102, w: 32)])
        #expect(found.map(\.startText) == [nil, "13:30"])
    }

    @Test func labelsTimesOverflowMarkersAndStrayGlyphsAreNotEntries() {
        let found = drafts([line(1, "28", x: 10, y: 60), line(40, "12:00", x: 150, y: 100, w: 32), line(41, "y 2 más", x: 10, y: 180),
                            line(42, "+3 more", x: 10, y: 200), line(43, "|", x: 10, y: 220), line(44, "oct", x: 10, y: 240), line(45, "Real entry", x: 10, y: 260)])
        #expect(found.map(\.title) == ["Real entry"])
    }
}
