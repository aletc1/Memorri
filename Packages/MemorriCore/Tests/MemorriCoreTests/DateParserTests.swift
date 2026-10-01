import Foundation
import Testing
@testable import MemorriCore

@Suite struct DateParserTests {
    private let en = [Locale(identifier: "en_US")]
    private let enGB = [Locale(identifier: "en_GB")]
    private let es = [Locale(identifier: "es_ES"), Locale(identifier: "en_US")]
    private let both = [Locale(identifier: "en_US"), Locale(identifier: "es_ES")]

    private func d(weekday: Int? = nil, day: Int? = nil, month: Int? = nil, year: Int? = nil, hour: Int? = nil, minute: Int? = nil,
                   relative: ParsedDate.Relative? = nil, orderAssumed: Bool = false) -> ParsedDate {
        ParsedDate(weekday: weekday, day: day, month: month, year: year, hour: hour, minute: minute, relative: relative, orderAssumed: orderAssumed)
    }

    private struct Row: Sendable {
        let text: String
        let expected: ParsedDate?
        let spanishFirst: Bool
    }

    private var table: [Row] {
        func r(_ text: String, _ expected: ParsedDate?, es: Bool = false) -> Row { Row(text: text, expected: expected, spanishFirst: es) }
        return [
            // English dates
            r("Friday 23 October", d(weekday: 5, day: 23, month: 10)),
            r("Friday 23 October 2026", d(weekday: 5, day: 23, month: 10, year: 2026)),
            r("Oct 14", d(day: 14, month: 10)),
            r("October 14th, 2026", d(day: 14, month: 10, year: 2026)),
            r("14 Oct", d(day: 14, month: 10)),
            r("Wed 14", d(weekday: 3, day: 14)),
            r("Mon 12", d(weekday: 1, day: 12)),
            r("1st November", d(day: 1, month: 11)),
            r("March 3rd", d(day: 3, month: 3)),
            r("Sept. 9", d(day: 9, month: 9)),
            r("Thursday, October 15, 2026", d(weekday: 4, day: 15, month: 10, year: 2026)),
            r("Wednesday, 14 October 2026 at 09:12", d(weekday: 3, day: 14, month: 10, year: 2026, hour: 9, minute: 12)),
            // numeric dates
            r("2026-11-06", d(day: 6, month: 11, year: 2026)),
            r("14/10/2026", d(day: 14, month: 10, year: 2026)),
            r("10/14/2026", d(day: 14, month: 10, year: 2026)),
            r("14/10", d(day: 14, month: 10)),
            r("10/14", d(day: 14, month: 10)),
            r("03/04", d(day: 4, month: 3, orderAssumed: true)),                 // en_US: month first
            r("03/04", d(day: 3, month: 4, orderAssumed: true), es: true),       // es_ES: day first
            r("4/5/26", d(day: 5, month: 4, year: 2026, orderAssumed: true)),
            // times
            r("10:00", d(hour: 10, minute: 0)),
            r("9:30 AM", d(hour: 9, minute: 30)),
            r("2:15 PM", d(hour: 14, minute: 15)),
            r("12 PM", d(hour: 12, minute: 0)),
            r("12 AM", d(hour: 0, minute: 0)),
            r("5pm", d(hour: 17, minute: 0)),
            r("17:45", d(hour: 17, minute: 45)),
            r("10:00 - 11:30", d(hour: 10, minute: 0)),
            r("a las 15:00", d(hour: 15, minute: 0), es: true),
            r("15h30", d(hour: 15, minute: 30), es: true),
            // relative English
            r("tomorrow", d(relative: .tomorrow)),
            r("today", d(relative: .today)),
            r("yesterday", d(relative: .yesterday)),
            r("tomorrow at 10:00", d(hour: 10, minute: 0, relative: .tomorrow)),
            r("in 2 days", d(relative: .inDays(2))),
            r("in 1 day", d(relative: .inDays(1))),
            r("next Monday", d(relative: .next(weekday: 1))),
            r("end of week", d(relative: .endOfWeek)),
            r("by the end of the week", d(relative: .endOfWeek)),
            // Spanish
            r("mañana", d(relative: .tomorrow), es: true),
            r("hoy", d(relative: .today), es: true),
            r("ayer", d(relative: .yesterday), es: true),
            r("mañana a las 15:00", d(hour: 15, minute: 0, relative: .tomorrow), es: true),
            r("en 3 días", d(relative: .inDays(3)), es: true),
            r("el próximo lunes", d(relative: .next(weekday: 1)), es: true),
            r("el lunes que viene", d(relative: .next(weekday: 1)), es: true),
            r("fin de semana", d(relative: .endOfWeek), es: true),
            r("14 de octubre de 2026", d(day: 14, month: 10, year: 2026), es: true),
            r("viernes 23 de octubre", d(weekday: 5, day: 23, month: 10), es: true),
            r("lun 12", d(weekday: 1, day: 12), es: true),
            r("mié 14", d(weekday: 3, day: 14), es: true),
            r("miércoles, 14 de octubre de 2026, 09:12", d(weekday: 3, day: 14, month: 10, year: 2026, hour: 9, minute: 12), es: true),
            r("sábado 17 oct.", d(weekday: 6, day: 17, month: 10), es: true),
            r("15 de enero", d(day: 15, month: 1), es: true),
            r("el viernes", d(weekday: 5), es: true),
            // weekday only
            r("Friday", d(weekday: 5)),
            r("by Friday", d(weekday: 5)),
            r("Mon", d(weekday: 1)),
            // not a date
            r("Team sync", nil),
            r("Room 4", nil),
            r("Budget figures", nil),
            r("4 people", nil),
            r("", nil),
            r("   ", nil),
        ]
    }

    @Test func theTableOfTexts() {
        #expect(table.count >= 40)
        for row in table {
            let parsed = DateParser.parse(row.text, locales: row.spanishFirst ? es : en)
            #expect(parsed == row.expected, Comment(rawValue: "\"\(row.text)\" → \(String(describing: parsed))"))
        }
    }

    @Test func anExplicitOrderDecidesAnAmbiguousNumericDate() {
        #expect(DateParser.parse("03/04", locales: en, order: .dmy) == d(day: 3, month: 4, orderAssumed: true))
        #expect(DateParser.parse("03/04", locales: es, order: .mdy) == d(day: 4, month: 3, orderAssumed: true))
        // An unambiguous date ignores the order it is given.
        #expect(DateParser.parse("14/10", locales: en, order: .mdy) == d(day: 14, month: 10))
    }

    @Test func britishEnglishReadsDayFirst() {
        #expect(DateParser.parse("03/04", locales: enGB) == d(day: 3, month: 4, orderAssumed: true))
    }

    @Test func marIsMarchInEnglishFirstAndTuesdayInSpanishFirst() {
        #expect(DateParser.parse("mar 13", locales: both) == d(day: 13, month: 3))
        #expect(DateParser.parse("mar 13", locales: es) == d(weekday: 2, day: 13))
    }

    @Test func accentsAndCaseDoNotMatter() {
        #expect(DateParser.parse("MIERCOLES 14 DE OCTUBRE", locales: es) == d(weekday: 3, day: 14, month: 10))
        #expect(DateParser.parse("FRIDAY", locales: en) == d(weekday: 5))
    }

    @Test func otherLanguagesComeFromTheLocaleSymbols() {
        #expect(DateParser.parse("14 octobre", locales: [Locale(identifier: "fr_FR")]) == d(day: 14, month: 10))
        #expect(DateParser.parse("Freitag", locales: [Locale(identifier: "de_DE")]) == d(weekday: 5))
    }

    @Test func dateOrderFromUnambiguousDates() {
        #expect(DateParser.dateOrder(ofUnambiguous: ["14/10"]) == .dmy)
        #expect(DateParser.dateOrder(ofUnambiguous: ["10/14"]) == .mdy)
        #expect(DateParser.dateOrder(ofUnambiguous: ["2026-10-14"]) == .ymd)
        #expect(DateParser.dateOrder(ofUnambiguous: ["03/04"]) == nil)
        #expect(DateParser.dateOrder(ofUnambiguous: ["14/10", "03/04", "25/12/2026"]) == .dmy)
        #expect(DateParser.dateOrder(ofUnambiguous: ["14/10", "10/14"]) == nil)
        #expect(DateParser.dateOrder(ofUnambiguous: []) == nil)
        #expect(DateParser.dateOrder(ofUnambiguous: ["Team sync", "Mon 12"]) == nil)
    }
}
