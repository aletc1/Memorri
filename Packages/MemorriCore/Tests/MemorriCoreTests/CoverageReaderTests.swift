import Foundation
import Testing
@testable import MemorriCore

/// What a captured week or day view really showed (spec 010 FR-001, FR-003; research R1): silence unless the view is read for certain.
@Suite struct CoverageReaderTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let whole = [PixelBox(x: 0, y: 0, width: 1600, height: 1000)]

    private func header(_ line: Int, _ x: Double, day: Int, assumed: Bool = false, conflict: Bool = false) -> DateHeader {
        DateHeader(line: line, midX: x, date: DateComponents(year: 2026, month: 10, day: day), monthAssumed: assumed, monthConflict: conflict)
    }

    /// Mon 12 to Fri 16 across a 1,000 px wide grid.
    private var week: [DateHeader] { (0..<5).map { header($0 + 1, 300 + Double($0) * 200, day: 12 + $0) } }

    private func label(_ n: Int, _ text: String, y: Int, x: Int = 20) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y - 10, width: 50, height: 20), confidence: 0.9)
    }

    /// 8 AM to 2 PM, 100 px an hour from y = 200.
    private var hours: [RecognisedLine] { ["8 AM", "9 AM", "10 AM", "11 AM", "12 PM", "1 PM", "2 PM"].enumerated().map { label(100 + $0.offset, $0.element, y: 200 + $0.offset * 100) } }

    private func read(_ kind: ScreenKind = .calendarWeek, headers: [DateHeader]? = nil, lines: [RecognisedLine]? = nil, visible: [PixelBox]? = nil,
                      zone: TimeZone? = nil) -> CoverageDraft? {
        CoverageReader.read(kind: kind, headers: headers ?? week, lines: lines ?? hours, visible: visible ?? whole, zone: zone ?? utc, windowKey: "w0")
    }

    private func date(_ day: Int, _ hour: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func aWeekViewGivesOneSpanPerDayBetweenTheFirstAndLastHourLabel() throws {
        let draft = try #require(read())
        #expect(draft.kind == .calendarWeek && draft.windowKey == "w0" && draft.spans.count == 5)
        #expect(draft.spans.first == DateInterval(start: date(12, 8, in: utc), end: date(12, 14, in: utc)))
        #expect(draft.spans.last == DateInterval(start: date(16, 8, in: utc), end: date(16, 14, in: utc)))
    }

    @Test func spansAreAbsoluteInstantsInTheViewsOwnZone() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let draft = try #require(read(zone: tokyo))
        #expect(draft.spans.first == DateInterval(start: date(12, 8, in: tokyo), end: date(12, 14, in: tokyo)))
        #expect(draft.spans.first?.start != date(12, 8, in: utc))
    }

    @Test func aDayViewHasOneHeaderAndOneSpan() throws {
        let draft = try #require(read(.calendarDay, headers: [header(1, 700, day: 14)]))
        #expect(draft.kind == .calendarDay && draft.spans == [DateInterval(start: date(14, 8, in: utc), end: date(14, 14, in: utc))])
    }

    @Test func twentyFourHourLabelsAndBareNumbersAreRead() throws {
        let twentyFour = ["08:00", "09:00", "10:00", "11:00"].enumerated().map { label(100 + $0.offset, $0.element, y: 200 + $0.offset * 100) }
        #expect(read(lines: twentyFour)?.spans.first == DateInterval(start: date(12, 8, in: utc), end: date(12, 11, in: utc)))
        let bare = ["10", "11", "12", "1", "2"].enumerated().map { label(100 + $0.offset, $0.element, y: 200 + $0.offset * 100) }
        #expect(read(lines: bare)?.spans.first == DateInterval(start: date(12, 10, in: utc), end: date(12, 14, in: utc)))
    }

    @Test func aMissingLabelDoesNotBreakTheAxisButAnIrregularOneDoes() throws {
        var skipped = hours; skipped.remove(at: 3)                                  // no 11 AM label, the 100 px grid is unchanged
        #expect(read(lines: skipped)?.spans.count == 5)
        var squeezed = hours; squeezed[3] = label(103, "11 AM", y: 340)             // a label where the grid does not put it
        #expect(read(lines: squeezed) == nil)
    }

    @Test func silenceWhenTheViewCannotBeReadForCertain() {
        #expect(read(.calendarMonth) == nil)
        #expect(read(.email) == nil)
        #expect(read(headers: []) == nil)
        #expect(read(headers: week.dropLast().map { $0 } + [header(9, 1100, day: 16, assumed: true)]) == nil)
        #expect(read(headers: week.dropLast().map { $0 } + [header(9, 1100, day: 16, conflict: true)]) == nil)
        #expect(read(lines: Array(hours.prefix(2))) == nil)                          // fewer than three hour labels
        #expect(read(lines: []) == nil)
        let decreasing = hours.reversed().enumerated().map { label(100 + $0.offset, $0.element.text, y: 200 + $0.offset * 100) }      // 2 PM at the top, 8 AM at the bottom
        #expect(read(lines: decreasing) == nil)
    }

    @Test func labelsMustSitInOneColumnLeftOfTheDays() {
        let scattered = hours.enumerated().map { label(100 + $0.offset, $0.element.text, y: $0.element.box.y + 10, x: 20 + $0.offset * 60) }
        #expect(read(lines: scattered) == nil)
    }

    @Test func aDayColumnHiddenBehindAnotherWindowIsLeftOut() throws {
        // Only the left part of the window shows: the days at x = 300, 500 and 700 are visible, the others are covered.
        let draft = try #require(read(visible: [PixelBox(x: 0, y: 0, width: 800, height: 1000)]))
        #expect(draft.spans.count == 3 && draft.spans.last?.start == date(14, 8, in: utc))
        // A covered stretch of the time axis hides the whole day: the window shows only the top part of the grid.
        #expect(read(visible: [PixelBox(x: 0, y: 0, width: 1600, height: 500)]) == nil)
    }

    @Test func labelsOutsideTheVisiblePartGiveNothing() {
        #expect(read(visible: [PixelBox(x: 100, y: 0, width: 1500, height: 1000)]) == nil)          // the axis itself is covered
    }
}
