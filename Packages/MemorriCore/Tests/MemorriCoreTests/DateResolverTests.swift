import Foundation
import Testing
@testable import MemorriCore

@Suite struct DateResolverTests {
    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let en = [Locale(identifier: "en_US"), Locale(identifier: "es_ES")]
    private let es = [Locale(identifier: "es_ES"), Locale(identifier: "en_US")]

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ zone: String = "Europe/Madrid") -> Date {
        SyntheticTime.date(y, m, d, h, min, zone: zone)
    }

    /// Wednesday 14 October 2026, 09:12 in Madrid.
    private var capture: Date { at(2026, 10, 14, 9, 12) }

    private func context(capture: Date? = nil, zone: TimeZone? = nil, headers: [DateHeader] = [], lines: [RecognisedLine] = [],
                         order: DateOrder? = nil, locales: [Locale]? = nil, sent: Date? = nil) -> ResolutionContext {
        ResolutionContext(captureTime: capture ?? self.capture, timezone: zone ?? madrid, headers: headers, lines: lines, dateOrder: order,
                          locales: locales ?? en, sentReference: sent)
    }

    private func draft(_ kind: FindingKind = .appointment, title: String = "Team sync", cited: [Int] = [1], start: String? = nil, end: String? = nil,
                       date: String? = nil, due: String? = nil, remind: String? = nil, allDay: Bool? = nil, column: Int? = nil,
                       sent: String? = nil) -> FindingDraft {
        FindingDraft(kind: kind, title: title, citedLines: cited, startText: start, endText: end, dateText: date, dueText: due, remindText: remind,
                     allDay: allDay, columnLine: column, sentText: sent)
    }

    private func line(_ n: Int, _ text: String, x: Int, y: Int = 100, w: Int = 100) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: 18), confidence: 0.9)
    }

    private struct Case {
        let name: String
        let text: String
        let field: String
        let expected: Date?
        let allDay: Bool
        let rule: String?
        var origin: FieldOrigin = .read
        var reason: String? = nil
        var locales: [Locale]? = nil
        var capture: Date? = nil
        var zone: TimeZone? = nil
        var order: DateOrder? = nil
        var sent: Date? = nil
    }

    private func check(_ c: Case, draft: FindingDraft? = nil, headers: [DateHeader] = [], lines: [RecognisedLine] = []) {
        let ctx = context(capture: c.capture, zone: c.zone, headers: headers, lines: lines, order: c.order, locales: c.locales, sent: c.sent)
        let result = DateResolver.resolve(text: c.text, field: c.field, draft: draft ?? self.draft(), in: ctx)
        #expect(result.date == c.expected, Comment(rawValue: "\(c.name): date \(String(describing: result.date))"))
        #expect(result.allDay == c.allDay, Comment(rawValue: "\(c.name): allDay"))
        #expect(result.provenance?.rule == c.rule, Comment(rawValue: "\(c.name): rule \(String(describing: result.provenance?.rule))"))
        if c.rule != nil {
            #expect(result.provenance?.origin == c.origin, Comment(rawValue: "\(c.name): origin"))
            #expect(result.provenance?.reason == c.reason, Comment(rawValue: "\(c.name): reason"))
        }
        #expect((result.unresolvedText != nil) == (c.rule == nil && !c.text.trimmingCharacters(in: .whitespaces).isEmpty), Comment(rawValue: "\(c.name): unresolved"))
    }

    // MARK: Table

    @Test func theRulesOneByOne() {
        let cases: [Case] = [
            // explicit-date
            Case(name: "weekday day month", text: "Friday 23 October", field: "due", expected: at(2026, 10, 23), allDay: true, rule: "explicit-date"),
            Case(name: "with year and time", text: "23 October 2027 10:00", field: "start", expected: at(2027, 10, 23, 10), allDay: false, rule: "explicit-date"),
            Case(name: "iso", text: "2026-11-06", field: "due", expected: at(2026, 11, 6), allDay: true, rule: "explicit-date"),
            Case(name: "day first numeric", text: "14/10/2026 14:00", field: "start", expected: at(2026, 10, 14, 14), allDay: false, rule: "explicit-date"),
            Case(name: "january after december capture", text: "Jan 3", field: "due", expected: at(2027, 1, 3), allDay: true, rule: "explicit-date",
                 capture: at(2026, 12, 28, 10)),
            Case(name: "december before january capture", text: "Dec 30", field: "due", expected: at(2026, 12, 30), allDay: true, rule: "explicit-date",
                 capture: at(2027, 1, 2, 10)),
            Case(name: "pm time", text: "Oct 14 at 2:30 PM", field: "start", expected: at(2026, 10, 14, 14, 30), allDay: false, rule: "explicit-date"),
            Case(name: "spanish", text: "14 de octubre de 2026", field: "due", expected: at(2026, 10, 14), allDay: true, rule: "explicit-date", locales: es),
            Case(name: "weekday and day only", text: "Wed 14", field: "start", expected: at(2026, 10, 14), allDay: true, rule: "explicit-date"),
            // relative-day
            Case(name: "tomorrow", text: "tomorrow", field: "due", expected: at(2026, 10, 15), allDay: true, rule: "relative-day"),
            Case(name: "tomorrow with time", text: "tomorrow at 10:00", field: "start", expected: at(2026, 10, 15, 10), allDay: false, rule: "relative-day"),
            Case(name: "today", text: "today", field: "due", expected: at(2026, 10, 14), allDay: true, rule: "relative-day"),
            Case(name: "yesterday", text: "yesterday", field: "start", expected: at(2026, 10, 13), allDay: true, rule: "relative-day"),
            Case(name: "in 3 days", text: "in 3 days", field: "due", expected: at(2026, 10, 17), allDay: true, rule: "relative-day"),
            Case(name: "next monday", text: "next Monday", field: "due", expected: at(2026, 10, 19), allDay: true, rule: "relative-day"),
            Case(name: "next wednesday is a week away", text: "next Wednesday", field: "due", expected: at(2026, 10, 21), allDay: true, rule: "relative-day"),
            Case(name: "manana with time", text: "mañana a las 15:00", field: "start", expected: at(2026, 10, 15, 15), allDay: false, rule: "relative-day", locales: es),
            // end-of-week
            Case(name: "end of week", text: "end of week", field: "due", expected: at(2026, 10, 16), allDay: true, rule: "end-of-week"),
            Case(name: "end of week seen on a saturday", text: "by the end of the week", field: "due", expected: at(2026, 10, 23), allDay: true, rule: "end-of-week",
                 capture: at(2026, 10, 17, 11)),
            Case(name: "fin de semana", text: "fin de semana", field: "due", expected: at(2026, 10, 16), allDay: true, rule: "end-of-week", locales: es),
            // weekday-only
            Case(name: "friday", text: "Friday", field: "due", expected: at(2026, 10, 16), allDay: true, rule: "weekday-only"),
            Case(name: "the same weekday counts today", text: "Wednesday", field: "due", expected: at(2026, 10, 14), allDay: true, rule: "weekday-only"),
            Case(name: "monday", text: "by Monday", field: "due", expected: at(2026, 10, 19), allDay: true, rule: "weekday-only"),
            Case(name: "viernes", text: "el viernes", field: "due", expected: at(2026, 10, 16), allDay: true, rule: "weekday-only", locales: es),
            Case(name: "weekday with time", text: "Friday 14:00", field: "start", expected: at(2026, 10, 16, 14), allDay: false, rule: "weekday-only"),
            // time-only
            Case(name: "time only", text: "10:00", field: "start", expected: at(2026, 10, 14, 10), allDay: false, rule: "time-only"),
            Case(name: "pm time only", text: "2:30 PM", field: "start", expected: at(2026, 10, 14, 14, 30), allDay: false, rule: "time-only"),
            // zones: a capture just after midnight where the date differs from the Mac's
            Case(name: "tomorrow in new york", text: "tomorrow at 9:00", field: "start", expected: at(2026, 10, 15, 9, 0, "America/New_York"), allDay: false,
                 rule: "relative-day", capture: at(2026, 10, 14, 23, 40, "UTC"), zone: newYork),
            Case(name: "tomorrow in madrid for the same capture", text: "tomorrow at 9:00", field: "start", expected: at(2026, 10, 16, 9), allDay: false,
                 rule: "relative-day", capture: at(2026, 10, 14, 23, 40, "UTC")),
            Case(name: "today just after midnight in madrid", text: "today", field: "due", expected: at(2026, 10, 15), allDay: true, rule: "relative-day",
                 capture: at(2026, 10, 14, 22, 10, "UTC")),
            Case(name: "today for the same capture in new york", text: "today", field: "due", expected: at(2026, 10, 14, 0, 0, "America/New_York"), allDay: true,
                 rule: "relative-day", capture: at(2026, 10, 14, 22, 10, "UTC"), zone: newYork),
            // the email's own date is the reference
            Case(name: "sent on monday", text: "tomorrow", field: "due", expected: at(2026, 10, 13), allDay: true, rule: "relative-day", sent: at(2026, 10, 12, 9, 12)),
            Case(name: "friday from a monday email", text: "Friday", field: "due", expected: at(2026, 10, 16), allDay: true, rule: "weekday-only", sent: at(2026, 10, 12, 9, 12)),
            // numeric order
            Case(name: "day first from the picture", text: "03/04/2026", field: "due", expected: at(2026, 4, 3), allDay: true, rule: "explicit-date", origin: .inferred,
                 reason: "date-order", order: .dmy),
            Case(name: "month first from the picture", text: "03/04/2026", field: "due", expected: at(2026, 3, 4), allDay: true, rule: "explicit-date", origin: .inferred,
                 reason: "date-order", order: .mdy),
            Case(name: "no order given uses the locale (the nearest March 4 is next year's)", text: "03/04", field: "due", expected: at(2027, 3, 4), allDay: true, rule: "explicit-date", origin: .inferred,
                 reason: "date-order"),
            Case(name: "unambiguous numeric is read", text: "14/10", field: "due", expected: at(2026, 10, 14), allDay: true, rule: "explicit-date", order: .mdy),
            // unresolved
            Case(name: "not a date", text: "sometime soon", field: "due", expected: nil, allDay: false, rule: nil),
            Case(name: "impossible date", text: "Feb 30", field: "due", expected: nil, allDay: false, rule: nil),
            Case(name: "impossible time", text: "25:00", field: "start", expected: nil, allDay: false, rule: nil),
            Case(name: "nothing", text: "", field: "start", expected: nil, allDay: false, rule: nil),
        ]
        #expect(cases.count >= 40)
        for c in cases { check(c) }
    }

    // MARK: Header columns

    private func weekHeaders() -> [DateHeader] {
        (0..<5).map { i in DateHeader(line: i + 1, midX: 200 + Double(i) * 300, date: DateComponents(year: 2026, month: 10, day: 12 + i)) }
    }

    @Test func aWeekViewBlockTakesTheDateOfTheNearestHeaderByHorizontalCentre() {
        let lines = [line(10, "10:00 Design review", x: 780, w: 200), line(11, "13:00 Sync", x: 1010, w: 100)]
        let headers = weekHeaders()
        check(Case(name: "wednesday column", text: "13:00", field: "start", expected: at(2026, 10, 14, 13), allDay: false, rule: "header-column"),
              draft: draft(cited: [10]), headers: headers, lines: lines)
        check(Case(name: "thursday column", text: "13:00", field: "start", expected: at(2026, 10, 15, 13), allDay: false, rule: "header-column"),
              draft: draft(cited: [11]), headers: headers, lines: lines)
    }

    @Test func theModelsColumnLineIsUsedWhenItIsAHeader() {
        let lines = [line(10, "13:00 Sync", x: 500, w: 100)]
        check(Case(name: "column line", text: "13:00", field: "start", expected: at(2026, 10, 16, 13), allDay: false, rule: "header-column"),
              draft: draft(cited: [10], column: 5), headers: weekHeaders(), lines: lines)
    }

    @Test func theEndTakesTheSameColumnAsTheStart() {
        let lines = [line(10, "10:00 Team sync", x: 480, w: 200)]
        check(Case(name: "end", text: "11:30", field: "end", expected: at(2026, 10, 13, 11, 30), allDay: false, rule: "header-column"),
              draft: draft(cited: [10], start: "10:00", end: "11:30"), headers: weekHeaders(), lines: lines)
    }

    @Test func aDayViewHasOneHeader() {
        let headers = [DateHeader(line: 1, midX: 600, date: DateComponents(year: 2026, month: 10, day: 14))]
        check(Case(name: "day view", text: "09:30", field: "start", expected: at(2026, 10, 14, 9, 30), allDay: false, rule: "header-column"),
              draft: draft(cited: [2]), headers: headers, lines: [line(2, "09:30 Stand-up", x: 300)])
    }

    @Test func aDateInTheTextBeatsTheHeader() {
        let lines = [line(10, "Tue 20 Oct 10:00 Team sync", x: 800)]
        check(Case(name: "explicit", text: "20 Oct 10:00", field: "start", expected: at(2026, 10, 20, 10), allDay: false, rule: "explicit-date"),
              draft: draft(cited: [10]), headers: weekHeaders(), lines: lines)
    }

    // MARK: Date from the other texts of the same finding

    @Test func aTimeTakesItsDayFromTheDateText() {
        check(Case(name: "date text", text: "10:00", field: "start", expected: at(2026, 10, 15, 10), allDay: false, rule: "explicit-date"),
              draft: draft(start: "10:00", date: "Thu 15"))
        check(Case(name: "relative date text", text: "10:00", field: "start", expected: at(2026, 10, 15, 10), allDay: false, rule: "relative-day"),
              draft: draft(start: "10:00", date: "tomorrow"))
    }

    @Test func anEndTimeTakesItsDayFromTheStart() {
        check(Case(name: "end from start", text: "11:00", field: "end", expected: at(2026, 10, 14, 11), allDay: false, rule: "explicit-date"),
              draft: draft(start: "14 Oct 10:00", end: "11:00"))
    }

    // MARK: Sent reference

    @Test func theSentTextGivesTheReference() {
        let ctx = context()
        let sent = DateResolver.sentReference(for: draft(sent: "Tue 13 Oct 2026 09:12"), in: ctx)
        #expect(sent == at(2026, 10, 13, 9, 12))
        #expect(DateResolver.sentReference(for: draft(), in: ctx) == nil)
        #expect(DateResolver.sentReference(for: draft(sent: "sent a while ago"), in: ctx) == nil)
    }

    // MARK: Deadline reminder

    private func deadline(_ due: String, title: String = "Submit the grant proposal", remind: String? = nil) -> FindingDraft {
        draft(.deadline, title: title, due: due, remind: remind)
    }

    @Test func aDeadlineWithAnActionGetsAReminderAtNineOnTheWorkingDayBefore() {
        let thursday = DateResolver.resolve(text: "", field: "remind", draft: deadline("2026-11-06"), in: context())
        #expect(thursday.date == at(2026, 11, 5, 9) && !thursday.allDay)
        #expect(thursday.provenance == FieldProvenance(origin: .inferred, rule: "deadline-reminder", reason: nil))
        let afterMonday = DateResolver.resolve(text: "", field: "remind", draft: deadline("2026-11-09"), in: context())
        #expect(afterMonday.date == at(2026, 11, 6, 9))
        let afterSunday = DateResolver.resolve(text: "", field: "remind", draft: deadline("2026-11-08"), in: context())
        #expect(afterSunday.date == at(2026, 11, 6, 9))
        let afterTuesday = DateResolver.resolve(text: "", field: "remind", draft: deadline("Tue 10 Nov"), in: context())
        #expect(afterTuesday.date == at(2026, 11, 9, 9))
    }

    @Test func theReminderUsesTheZoneOfTheContext() {
        let result = DateResolver.resolve(text: "", field: "remind", draft: deadline("2026-11-06"), in: context(zone: newYork))
        #expect(result.date == at(2026, 11, 5, 9, 0, "America/New_York"))
    }

    @Test func literalReminderTextIsUsedAsRead() {
        let d = deadline("2026-11-06", remind: "Nov 5 at 8:00")
        let result = DateResolver.resolve(text: "Nov 5 at 8:00", field: "remind", draft: d, in: context())
        #expect(result.date == at(2026, 11, 5, 8) && result.provenance == FieldProvenance(origin: .read, rule: "explicit-date", reason: nil))
    }

    @Test func literalReminderTextThatCannotBeReadIsKeptAndNoReminderIsInvented() {
        let d = deadline("2026-11-06", remind: "15 minutes before")
        let result = DateResolver.resolve(text: "15 minutes before", field: "remind", draft: d, in: context())
        #expect(result.date == nil && result.unresolvedText == "15 minutes before" && result.provenance == nil)
    }

    @Test func aDeadlineWithOnlyADateGetsNoReminder() {
        for title in ["Deadline", "Due date", "Fecha límite", "deadline"] {
            let result = DateResolver.resolve(text: "", field: "remind", draft: deadline("2026-11-06", title: title), in: context())
            #expect(result.date == nil && result.provenance == nil && result.unresolvedText == nil, Comment(rawValue: title))
        }
        #expect(DateResolver.titleHasAction("Submit the grant proposal") && DateResolver.titleHasAction("Project deadline"))
    }

    @Test func otherKindsAndUnresolvedDueDatesGetNoReminder() {
        let task = DateResolver.resolve(text: "", field: "remind", draft: draft(.task, title: "Send report", due: "Friday"), in: context())
        #expect(task.date == nil && task.provenance == nil)
        let vague = DateResolver.resolve(text: "", field: "remind", draft: deadline("sometime"), in: context())
        #expect(vague.date == nil && vague.provenance == nil && vague.unresolvedText == nil)
    }

    // MARK: Headers

    private func headerLines(_ texts: [(String, Int)], title: String? = nil) -> [RecognisedLine] {
        var lines: [RecognisedLine] = []
        if let title { lines.append(line(1, title, x: 20, y: 20, w: 300)) }
        for (i, item) in texts.enumerated() { lines.append(line(lines.count + 1, item.0, x: item.1, y: 100, w: 60)) }
        return lines
    }

    @Test func headersAreFoundInAWeekViewWithTheMonthFromTheTitle() {
        let lines = headerLines([("Mon 12", 100), ("Tue 13", 400), ("Wed 14", 700), ("Thu 15", 1000), ("Fri 16", 1300), ("09:00", 20), ("Design review", 720)],
                                title: "October 12 – 16, 2026")
        let headers = DateResolver.headers(in: lines, locales: en, reference: capture, timezone: madrid)
        #expect(headers.map(\.date.day) == [12, 13, 14, 15, 16] && headers.allSatisfy { $0.date.month == 10 && $0.date.year == 2026 })
        #expect(headers.map(\.line) == [2, 3, 4, 5, 6])
        #expect(headers[0].midX == 130 && headers[4].midX == 1330)
    }

    @Test func headersInSpanishCome_FromTheLocale() {
        let lines = headerLines([("lun 12", 100), ("mar 13", 400), ("mié 14", 700)], title: "12 – 16 de octubre de 2026")
        let headers = DateResolver.headers(in: lines, locales: es, reference: capture, timezone: madrid)
        #expect(headers.map(\.date.day) == [12, 13, 14] && headers.allSatisfy { $0.date.month == 10 })
    }

    @Test func aWeekAcrossTheNewYearGetsTheRightYears() {
        let lines = headerLines([("Mon 28", 100), ("Tue 29", 400), ("Wed 30", 700), ("Thu 31", 1000), ("Fri 1", 1300)])
        let headers = DateResolver.headers(in: lines, locales: en, reference: at(2026, 12, 29, 10), timezone: madrid)
        let dates = headers.map { DateComponents(year: $0.date.year, month: $0.date.month, day: $0.date.day) }
        #expect(dates == [DateComponents(year: 2026, month: 12, day: 28), DateComponents(year: 2026, month: 12, day: 29), DateComponents(year: 2026, month: 12, day: 30),
                          DateComponents(year: 2026, month: 12, day: 31), DateComponents(year: 2027, month: 1, day: 1)])
    }

    @Test func aDayViewTitleIsTheHeader() {
        let lines = [line(1, "Wednesday, October 14, 2026", x: 20, y: 20, w: 400), line(2, "09:00", x: 20, y: 120)]
        let headers = DateResolver.headers(in: lines, locales: en, reference: capture, timezone: madrid)
        #expect(headers.count == 1 && headers[0].date == DateComponents(year: 2026, month: 10, day: 14) && headers[0].line == 1)
    }

    @Test func linesWithTimesTitlesAndPlainTextAreNotHeaders() {
        let lines = [line(1, "October 12 – 16, 2026", x: 20), line(2, "Wednesday, 14 October 2026 at 09:12", x: 20), line(3, "Team sync", x: 20),
                     line(4, "Friday", x: 20), line(5, "10:00 Mon 12", x: 20)]
        #expect(DateResolver.headers(in: lines, locales: en, reference: capture, timezone: madrid).isEmpty)
    }
}
