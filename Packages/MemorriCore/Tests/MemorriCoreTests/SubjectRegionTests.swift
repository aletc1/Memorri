import Foundation
import Testing
@testable import MemorriCore

@Suite struct SubjectRegionTests {
    private func line(_ n: Int, _ text: String, x: Int, y: Int, w: Int = 100) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: 18), confidence: 0.9)
    }

    /// A month grid of 7 columns of 200 pixels starting at x = 1000 and rows of 150 starting at y = 200 (label centres).
    private func cells() -> [DateHeader] {
        (0..<35).map { i in
            DateHeader(line: i + 1, midX: 1100 + Double(i % 7) * 200, midY: 209 + Double(i / 7) * 150, cellWidth: 200,
                       date: DateComponents(year: 2026, month: 10, day: i + 1))
        }
    }

    @Test func aMonthGridKeepsOnlyTheLinesInsideIt() {
        let all = [line(1, "inside", x: 1050, y: 230), line(2, "left window", x: 300, y: 400), line(3, "right of grid", x: 2500, y: 300),
                   line(4, "above grid", x: 1200, y: 60), line(5, "last row", x: 2000, y: 200 + 4 * 150 + 40),
                   line(6, "below grid", x: 1200, y: 200 + 5 * 150 + 120)]
        let kept = SubjectRegion.lines(all, kind: .calendarMonth, headers: [], cells: cells())
        #expect(kept.map(\.text) == ["inside", "last row"])
        #expect(kept.map(\.n) == [1, 5])                     // lines keep their numbers: citations refer to the whole list
    }

    @Test func aWeekViewKeepsTheColumnsAndDropsTheHourScaleAndOtherWindows() {
        let headers = (0..<5).map { DateHeader(line: $0 + 1, midX: 400 + Double($0) * 300, midY: 100, date: DateComponents(year: 2026, month: 10, day: 12 + $0)) }
        let all = [line(1, "block", x: 700, y: 400), line(2, "08:00", x: 20, y: 300, w: 60), line(3, "far right", x: 2200, y: 400),
                   line(4, "header", x: 400, y: 91)]
        let kept = SubjectRegion.lines(all, kind: .calendarWeek, headers: headers, cells: [])
        #expect(kept.map(\.text) == ["block", "header"])
    }

    @Test func withoutAGridEverythingIsKept() {
        let all = [line(1, "a", x: 10, y: 10), line(2, "b", x: 900, y: 900)]
        #expect(SubjectRegion.lines(all, kind: .calendarMonth, headers: [], cells: []) == all)
        #expect(SubjectRegion.lines(all, kind: .calendarWeek, headers: [], cells: []) == all)
        #expect(SubjectRegion.lines(all, kind: .calendarDay, headers: [], cells: cells()) == all)
        #expect(SubjectRegion.lines(all, kind: .email, headers: [], cells: []) == all)
    }
}
