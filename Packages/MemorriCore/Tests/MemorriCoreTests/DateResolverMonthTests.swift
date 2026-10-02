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
            // One digit is narrower than two, so the edge a label is aligned to is the one that stays put.
            let width = number >= 10 ? 22 : 11
            let x = (i % 7) * 200 + (rightAligned ? 172 - width : 10), y = 60 + (i / 7) * 150
            lines.append(RecognisedLine(n: n, text: "\(number)", box: PixelBox(x: x, y: y, width: width, height: 18), confidence: 0.9)); n += 1
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
        #expect(headers.count == 42 && headers.filter { $0.line > 0 }.count == 36)
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

    @Test func numbersFromOtherWindowsDoNotSpoilTheGrid() {
        // A clock and a page number far to the left of the calendar, in columns of their own.
        let strays = [RecognisedLine(n: 200, text: "1", box: PixelBox(x: -650, y: 40, width: 11, height: 18), confidence: 0.9),
                      RecognisedLine(n: 201, text: "88", box: PixelBox(x: -300, y: 480, width: 22, height: 18), confidence: 0.9),
                      RecognisedLine(n: 202, text: "00", box: PixelBox(x: -300, y: 300, width: 22, height: 18), confidence: 0.9),
                      RecognisedLine(n: 203, text: "18", box: PixelBox(x: -296, y: 380, width: 22, height: 18), confidence: 0.9),
                      RecognisedLine(n: 204, text: "11", box: PixelBox(x: -296, y: 420, width: 22, height: 18), confidence: 0.9)]
        let lines = grid() + strays
        let headers = cells(lines)
        #expect(dayOf(lines, headers, row: 0, column: 3) == "2026-10-1" && dayOf(lines, headers, row: 1, column: 0) == "2026-10-5")
        #expect(!headers.contains { strays.map(\.n).contains($0.line) })
    }

    @Test func aMonthNameBesideTheFirstDayIsStillThatDay() {
        var lines = grid()
        let first = lines.firstIndex { $0.text == "1" }!
        lines[first] = RecognisedLine(n: lines[first].n, text: "oct", box: PixelBox(x: 610, y: 60, width: 30, height: 18), confidence: 0.9)
        // The name is not a number, so no label carries it, but the cell is still there for entries inside it.
        let headers = cells(lines)
        #expect(headers.count == 42)
        #expect(headers.contains { $0.date.month == 10 && $0.date.day == 1 && $0.midX > 600 && $0.midX < 800 })
        #expect(dayOf(lines, headers, row: 1, column: 3) == "2026-10-8")
    }

    @Test func aDayNumberWithOrWithoutAMonthNameIsACellLabel() {
        for text in ["1", "31", "oct", "1 oct", "oct 1", "1 oct."] { #expect(DateResolver.isCellLabel(text, locales: es), "\(text)") }
        for text in ["10:00", "2026", "123", "ten", "1 foo", "12 oct 2026", ""] { #expect(!DateResolver.isCellLabel(text, locales: es), "\(text)") }
    }

    @Test func timesAndOtherNumbersAreNotCells() {
        let lines = grid() + [RecognisedLine(n: 99, text: "09:30 Budget", box: PixelBox(x: 10, y: 90, width: 100, height: 18), confidence: 0.9),
                              RecognisedLine(n: 100, text: "2026", box: PixelBox(x: 10, y: 20, width: 40, height: 18), confidence: 0.9),
                              RecognisedLine(n: 101, text: "45", box: PixelBox(x: 10, y: 20, width: 40, height: 18), confidence: 0.9)]
        #expect(cells(lines).filter { $0.line > 0 }.count == 36)
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

    @Test func theCellTheEntrySitsInGivesTheDayEvenWhenTheModelNamesAnotherLabel() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "09:00 Budget meeting", box: PixelBox(x: 10, y: 60 + 150 + 30, width: 160, height: 18), confidence: 0.9))   // Monday 5
        let labelForThe6th = lines.first { $0.text == "6" }!.n
        let result = DateResolver.resolve(text: "09:00", field: "start", draft: draft(cited: [eventLine], start: "09:00", column: labelForThe6th), in: resolver(lines))
        #expect(result.date == at(2026, 10, 5, 9, 0) && result.provenance == FieldProvenance(origin: .read, rule: "month-cell"))
    }

    @Test func theModelsLabelIsUsedForALineWithoutAPosition() {
        let lines = grid()
        let label = lines.first { $0.text == "6" }!.n
        let result = DateResolver.resolve(text: "09:00", field: "start", draft: draft(cited: [999], start: "09:00", column: label), in: resolver(lines))
        #expect(result.date == at(2026, 10, 6, 9, 0) && result.provenance?.rule == "month-cell")
    }

    @Test func aDayLabelTheReadingMissedStillHasItsCell() {
        // The reading drops single digits ("6", "8", "1" and "3" here); the cells are still there with the right dates.
        var lines = grid().filter { !["6", "8", "3"].contains($0.text) || $0.box.y > 60 + 4 * 150 }
        lines = lines.enumerated().map { RecognisedLine(n: $0.offset + 1, text: $0.element.text, box: $0.element.box, confidence: 0.9) }
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "10:00 Budget meeting", box: PixelBox(x: 210, y: 60 + 150 + 30, width: 160, height: 18), confidence: 0.9))  // Tuesday 6
        let result = DateResolver.resolve(text: "10:00", field: "start", draft: draft(cited: [eventLine], start: "10:00"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 6, 10, 0))
        #expect(cells(lines).count == 42)
    }

    @Test func theLabelAboveTheLineInItsColumnGivesTheDay() {
        var lines = grid()
        let eventLine = lines.count + 1
        // Row 3 (from 0), column 1: Tuesday 20 October.
        lines.append(RecognisedLine(n: eventLine, text: "14:30 Budget meeting", box: PixelBox(x: 210, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "14:30", field: "start", draft: draft(cited: [eventLine], start: "14:30"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 20, 14, 30) && result.provenance?.rule == "month-cell")
    }

    @Test func aLabelAtTheRightOfItsCellStillFindsItsCell() {
        var lines = grid(rightAligned: true)
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "16:00 Workshop", box: PixelBox(x: 410, y: 60 + 2 * 150 + 30, width: 140, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "16:00", field: "start", draft: draft(cited: [eventLine], start: "16:00"), in: resolver(lines))   // row 2, column 2
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

    @Test func aBareDayNumberInDateTextDoesNotStopAnAllDayEntryFromUsingItsCell() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "Training", box: PixelBox(x: 10, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "", field: "start", draft: draft(cited: [eventLine], start: "", date: "19"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 19) && result.allDay)
    }

    @Test func aBareDayNumberAsTheOnlyTextGivesTheAllDayCell() {
        var lines = grid()
        let eventLine = lines.count + 1
        lines.append(RecognisedLine(n: eventLine, text: "Training", box: PixelBox(x: 10, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))
        let result = DateResolver.resolve(text: "19", field: "start", draft: draft(cited: [eventLine], date: "19"), in: resolver(lines))
        #expect(result.date == at(2026, 10, 19) && result.allDay && result.provenance?.rule == "month-cell")
    }

    // MARK: a month that is not the capture's month (the day numbers alone cannot say which month it is)

    /// Six rows from Monday 12 January 2026 (labels as in a real month view that scrolls), the first of February labelled `1 feb`.
    /// Mondays fell on the 12th in October 2026 too, with 31 days in both months, so this grid is the same grid as 12 October to 22 November:
    /// only the words on the screen say which it is.
    private func februaryGrid(title: String?, firstLabel: String = "1 feb") -> [RecognisedLine] {
        var lines: [RecognisedLine] = []
        var n = 1
        if let title { lines.append(RecognisedLine(n: n, text: title, box: PixelBox(x: 20, y: 10, width: 200, height: 24), confidence: 0.9)); n += 1 }
        for (i, number) in (Array(12...31) + Array(1...22)).enumerated() {
            let text = i == 20 ? firstLabel : "\(number)"
            let width = text.count > 2 ? 34 : (number >= 10 ? 22 : 11)
            lines.append(RecognisedLine(n: n, text: text, box: PixelBox(x: (i % 7) * 200 + 10, y: 60 + (i / 7) * 150, width: width, height: 18), confidence: 0.9)); n += 1
        }
        return lines
    }

    private func span(_ headers: [DateHeader]) -> String {
        func text(_ h: DateHeader?) -> String { h.map { "\($0.date.year!)-\($0.date.month!)-\($0.date.day!)" } ?? "none" }
        return "\(text(headers.first)) to \(text(headers.last))"
    }

    @Test func aSpanishTitleNamingAnotherMonthThanTheCapturesWins() {
        let headers = cells(februaryGrid(title: "Febrero de 2026"), locales: es)
        #expect(span(headers) == "2026-1-12 to 2026-2-22" && headers.allSatisfy { !$0.monthAssumed })
    }

    @Test func anEnglishTitleNamingAnotherMonthThanTheCapturesWins() {
        let headers = cells(februaryGrid(title: "February 2026"))
        #expect(span(headers) == "2026-1-12 to 2026-2-22" && headers.allSatisfy { !$0.monthAssumed })
    }

    @Test func aTitleWithoutAYearIsReadWithTheCapturesYear() {
        let headers = cells(februaryGrid(title: "February"), reference: at(2026, 10, 14, 9))
        #expect(span(headers) == "2026-1-12 to 2026-2-22")
    }

    @Test func withoutATitleAMonthNameOnTheFirstDayGivesTheMonth() {
        let headers = cells(februaryGrid(title: nil))
        #expect(span(headers) == "2026-1-12 to 2026-2-22" && headers.allSatisfy { !$0.monthAssumed })
    }

    @Test func withNothingNamingTheMonthTheCapturesMonthIsUsedAndSaidToBeAssumed() {
        let headers = cells(februaryGrid(title: nil, firstLabel: "1"))
        #expect(headers.count == 42 && headers.allSatisfy(\.monthAssumed))
        #expect(headers.allSatisfy { ($0.date.month ?? 0) >= 9 })                  // around the capture's October, not January
        #expect(cells(grid(title: nil)).allSatisfy(\.monthAssumed) && cells(grid()).allSatisfy { !$0.monthAssumed })
    }

    @Test func aMonthTitleOutsideTheGridsColumnsDoesNotBeatTheOneAboveIt() {
        // A side bar's small calendar says October 2026 and sits nearer the grid than its real title does.
        var lines = februaryGrid(title: "Febrero de 2026")
        lines.append(RecognisedLine(n: 500, text: "Octubre de 2026", box: PixelBox(x: -700, y: 30, width: 200, height: 24), confidence: 0.9))
        #expect(span(cells(lines, locales: es)) == "2026-1-12 to 2026-2-22")
    }

    @Test func aTitleIsALineThatOnlyNamesAMonthAndYear() {
        for text in ["Febrero de 2026", "February 2026", "febrero", "Oct 2026", "Octubre"] { #expect(DateResolver.monthTitle(text, locales: es) != nil, "\(text)") }
        for text in ["Febrero de 2026 reunión", "Review of 2026 plans", "12 de febrero", "1 feb", "Mayo 40", "oct", "sep", ""] { #expect(DateResolver.monthTitle(text, locales: es) == nil, "\(text)") }
        #expect(DateResolver.monthTitle("Febrero de 2026", locales: es)?.month == 2 && DateResolver.monthTitle("Febrero de 2026", locales: es)?.year == 2026)
    }

    @Test func theTextOfAnotherWindowCannotNameTheMonth() {
        // The calendar window holds the grid; a browser window behind it shows a month name above a block of numbers.
        let lines = februaryGrid(title: nil, firstLabel: "1") + [RecognisedLine(n: 300, text: "1 abr", box: PixelBox(x: 2300, y: 60, width: 34, height: 18), confidence: 0.9)]
        let windows = [WindowInfo(appName: "Calendar", bundleID: nil, title: nil, frame: PixelBox(x: 0, y: 0, width: 1400, height: 1000), stack: 0),
                       WindowInfo(appName: "Browser", bundleID: nil, title: nil, frame: PixelBox(x: 1500, y: 0, width: 1000, height: 1000), stack: 1)]
        #expect(DateResolver.labelMonth(in: lines, locales: es) == 4)                           // read over the whole screen, the other window leaks in
        let own = SubjectRegion.visibleLines(lines, around: (110, 70), windows: windows)
        #expect(own?.contains { $0.n == 300 } == false && own?.count == lines.count - 1)
        #expect(own.flatMap { DateResolver.labelMonth(in: $0, locales: es) } == nil)
    }

    @Test func aWindowInFrontCoversTheLinesBehindIt() {
        let lines = [RecognisedLine(n: 1, text: "a", box: PixelBox(x: 100, y: 100, width: 10, height: 10), confidence: 0.9),
                     RecognisedLine(n: 2, text: "b", box: PixelBox(x: 900, y: 100, width: 10, height: 10), confidence: 0.9)]
        let calendar = WindowInfo(appName: "Calendar", bundleID: nil, title: nil, frame: PixelBox(x: 0, y: 0, width: 1000, height: 500), stack: 1)
        let dialog = WindowInfo(appName: "Dialog", bundleID: nil, title: nil, frame: PixelBox(x: 800, y: 0, width: 300, height: 300), stack: 0)
        #expect(SubjectRegion.visibleLines(lines, around: (100, 100), windows: [calendar, dialog])?.map(\.n) == [1])
        #expect(SubjectRegion.visibleLines(lines, around: (100, 100), windows: [calendar]) == nil)                  // one window: nothing to narrow
        let unstacked = WindowInfo(appName: "Calendar", bundleID: nil, title: nil, frame: calendar.frame, stack: nil)
        #expect(SubjectRegion.visibleLines(lines, around: (100, 100), windows: [unstacked, dialog]) == nil)         // no stack order recorded
    }
}
