import Foundation
import Testing
@testable import MemorriCore

/// A month view: the day numbers of its cells are the headers of the events inside them.
@Suite struct DateResolverMonthTests {
    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private let en = [Locale(identifier: "en_US"), Locale(identifier: "es_ES")]
    private let es = [Locale(identifier: "es_ES"), Locale(identifier: "en_US")]
    private var capture: Date { SyntheticTime.date(2026, 10, 14, 9, 12, zone: "Europe/Madrid") }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date { SyntheticTime.date(y, m, d, h, min, zone: "Europe/Madrid") }

    /// October 2026 from Monday 28 September: labels at the top-left of 200 x 150 cells, line 1 the title. Labels are lines 2...36.
    private func grid(title: String? = "October 2026", rightAligned: Bool = false) -> [RecognisedLine] {
        let numbers = Array(28...30) + Array(1...31) + [1, 2]
        var lines: [RecognisedLine] = []
        var n = 1
        if let title { lines.append(RecognisedLine(n: n, text: title, box: PixelBox(x: 20, y: 10, width: 200, height: 24), confidence: 0.9)); n += 1 }
        for (i, number) in numbers.enumerated() {
            let x = (i % 7) * 200 + (rightAligned ? 150 : 10), y = 60 + (i / 7) * 150
            lines.append(RecognisedLine(n: n, text: "\(number)", box: PixelBox(x: x, y: y, width: 22, height: 18), confidence: 0.9)); n += 1
        }
        return lines
    }

    private func cells(_ lines: [RecognisedLine], locales: [Locale]? = nil, reference: Date? = nil) -> [DateHeader] {
        DateResolver.monthCells(in: lines, locales: locales ?? en, reference: reference ?? capture, timezone: madrid)
    }

    private func dayOf(_ lines: [RecognisedLine], _ headers: [DateHeader], row: Int, column: Int) -> String? {
        let index = row * 7 + column + (lines.first?.text == "October 2026" || lines.first?.text.contains("2026") == true ? 1 : 0)
        let line = lines[index]
        return headers.first { $0.line == line.n }.map { "\($0.date.year!)-\($0.date.month!)-\($0.date.day!)" }
    }

    @Test func everyDayLabelGetsItsDateAndTheSpillDaysBelongToTheNeighbouringMonths() {
        let lines = grid()
        let headers = cells(lines)
        #expect(headers.count == 36)
        #expect(dayOf(lines, headers, row: 0, column: 0) == "2026-9-28")
        #expect(dayOf(lines, headers, row: 0, column: 3) == "2026-10-1")
        #expect(dayOf(lines, headers, row: 1, column: 0) == "2026-10-5")
        #expect(dayOf(lines, headers, row: 4, column: 0) == "2026-10-26")
        #expect(dayOf(lines, headers, row: 4, column: 4) == "2026-10-30")
        #expect(dayOf(lines, headers, row: 4, column: 5) == "2026-10-31")
        #expect(dayOf(lines, headers, row: 4, column: 6) == "2026-11-1")
        #expect(dayOf(lines, headers, row: 5, column: 0) == "2026-11-2")
    }

    @Test func aSpanishTitleGivesTheMonthToo() {
        let lines = grid(title: "octubre de 2026")
        #expect(dayOf(lines, cells(lines, locales: es), row: 1, column: 3) == "2026-10-8")
    }

    @Test func withoutATitleTheMonthOfTheCaptureIsUsed() {
        let lines = grid(title: nil)
        let headers = cells(lines)
        #expect(dayOf(lines, headers, row: 0, column: 0) == "2026-9-28" && dayOf(lines, headers, row: 2, column: 2) == "2026-10-14")
    }

    @Test func aYearBoundaryRollsTheYear() {
        // January 2027 starts on a Friday, so the grid starts on Monday 28 December.
        var lines = [RecognisedLine(n: 1, text: "January 2027", box: PixelBox(x: 20, y: 10, width: 200, height: 24), confidence: 0.9)]
        for (i, number) in (Array(28...31) + Array(1...31)).enumerated() {
            lines.append(RecognisedLine(n: i + 2, text: "\(number)", box: PixelBox(x: (i % 7) * 200 + 10, y: 60 + (i / 7) * 150, width: 22, height: 18), confidence: 0.9))
        }
        let headers = DateResolver.monthCells(in: lines, locales: en, reference: at(2027, 1, 14), timezone: madrid)
        #expect(headers.first { $0.line == 2 }?.date.year == 2026 && headers.first { $0.line == 2 }?.date.month == 12)
        #expect(headers.first { $0.line == 6 }?.date.year == 2027 && headers.first { $0.line == 6 }?.date.month == 1)
    }

    @Test func timesAndOtherNumbersAreNotCells() {
        let lines = grid() + [RecognisedLine(n: 99, text: "09:30 Budget", box: PixelBox(x: 10, y: 90, width: 100, height: 18), confidence: 0.9),
                              RecognisedLine(n: 100, text: "2026", box: PixelBox(x: 10, y: 20, width: 40, height: 18), confidence: 0.9),
                              RecognisedLine(n: 101, text: "45", box: PixelBox(x: 10, y: 20, width: 40, height: 18), confidence: 0.9)]
        #expect(cells(lines).count == 36)
    }

    @Test func fewerThanSevenLabelsIsNotAMonthGrid() {
        #expect(cells(Array(grid().prefix(6))).isEmpty)
    }

    // MARK: Resolving inside a cell

    private func resolver(_ lines: [RecognisedLine]) -> ResolutionContext {
        ResolutionContext(captureTime: capture, timezone: madrid, lines: lines, locales: en, cells: cells(lines))
    }
    private func draft(cited: [Int], start: String? = nil, column: Int? = nil, allDay: Bool? = nil, date: String? = nil) -> FindingDraft {
        FindingDraft(kind: .appointment, title: "Budget meeting", citedLines: cited, startText: start, dateText: date, allDay: allDay, columnLine: column)
    }

    @Test func theCellTheModelNamesGivesTheDay() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "09:00 Budget meeting", box: PixelBox(x: 10, y: 60 + 150 + 30, width: 160, height: 18), confidence: 0.9))
        let labelForThe6th = lines.first { $0.text == "6" }!.n
        let result = DateResolver.resolve(text: "09:00", field: "start", draft: draft(cited: [eventLine], start: "09:00", column: labelForThe6th), in: resolver(lines))
        #expect(result.date == at(2026, 10, 6, 9, 0) && result.provenance == FieldProvenance(origin: .read, rule: "month-cell"))
    }

    @Test func withoutTheModelsCellTheLabelAboveTheLineInItsColumnIsUsed() {
        var lines = grid()
        let eventLine = lines.count + 1
        // Row 3 (from 0), column 1: Tuesday 20 October.
        lines.append(RecognisedLine(n: eventLine, text: "14:30 Budget meeting", box: PixelBox(x: 210, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "14:30", field: "start", draft: draft(cited: [eventLine], start: "14:30"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 20, 14, 30) && result.provenance?.rule == "month-cell")
    }

    @Test func aLabelAtTheRightOfItsCellStillFindsItsCellWhenTheModelNamesIt() {
        var lines = grid(rightAligned: true)
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "16:00 Workshop", box: PixelBox(x: 410, y: 60 + 2 * 150 + 30, width: 140, height: 18), confidence: 0.9))
        let label = lines.first { $0.text == "14" }!.n                     // row 2, column 2: Wednesday 14
        let result = DateResolver.resolve(text: "16:00", field: "start", draft: draft(cited: [eventLine], start: "16:00", column: label), in: resolver(lines))
        #expect(result.date == at(2026, 10, 14, 16, 0))
    }

    @Test func anEntryWithoutATimeIsAllDayOnItsCell() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "Training", box: PixelBox(x: 10, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "", field: "start", draft: draft(cited: [eventLine]), in: resolver(lines))
        #expect(result.date == at(2026, 10, 19) && result.allDay && result.provenance == FieldProvenance(origin: .read, rule: "month-cell"))
    }

    @Test func aDateWrittenNextToTheTimeBeatsTheCell() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "09:00 Budget meeting", box: PixelBox(x: 10, y: 60 + 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "09:00", field: "start", draft: draft(cited: [eventLine], start: "09:00", date: "October 22, 2026"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 22, 9, 0) && result.provenance?.rule == "explicit-date")
    }
}
