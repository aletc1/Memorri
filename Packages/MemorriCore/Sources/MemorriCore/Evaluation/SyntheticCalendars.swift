import CoreGraphics
import Foundation

/// A calendar day as (year, month, day).
struct SyntheticDay: Sendable {
    let year: Int, month: Int, day: Int
    init(_ year: Int, _ month: Int, _ day: Int) { self.year = year; self.month = month; self.day = day }

    func date(_ hour: Int = 0, _ minute: Int = 0, zone: String) -> Date { SyntheticTime.date(year, month, day, hour, minute, zone: zone) }

    func adding(_ days: Int) -> SyntheticDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let moved = calendar.dateComponents([.year, .month, .day], from: base.addingTimeInterval(Double(days) * 86400))
        return SyntheticDay(moved.year!, moved.month!, moved.day!)
    }
}

enum SyntheticWords {
    static func dayName(_ offsetFromMonday: Int, _ language: SyntheticLanguage, short: Bool) -> String {
        let en = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let es = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
        let full = language == .en ? en[offsetFromMonday] : es[offsetFromMonday]
        return short ? String(full.prefix(3)) : full
    }

    static func monthName(_ month: Int, _ language: SyntheticLanguage) -> String {
        let en = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let es = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
        return language == .en ? en[month - 1] : es[month - 1]
    }

    static func clock(_ hour: Int, _ minute: Int, clock24: Bool) -> String {
        if clock24 { return String(format: "%02d:%02d", hour, minute) }
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }

    static func hourLabel(_ hour: Int, clock24: Bool) -> String {
        clock24 ? String(format: "%02d:00", hour) : "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }
}

/// A block on a week or day view, or a chip on a month view.
struct SyntheticEvent: Sendable {
    let title: String
    let day: Int
    let hour: Int
    let minute: Int
    let minutes: Int
    var place: String? = nil
    var allDay = false
}

private let blockColours: [(light: RGB, dark: RGB)] = [(RGB(0xCFE4FA), RGB(0x35507A)), (RGB(0xD5F0D5), RGB(0x3A6B3A)),
                                                       (RGB(0xFBE3C6), RGB(0x7A5A2E)), (RGB(0xEAD5F2), RGB(0x6B3F7A))]

enum SyntheticCalendars {
    /// Week (five columns) and day (one column) views with an hour scale; the end of every block is read from its height.
    static func timeGrid(_ c: SyntheticCanvas, _ area: CGRect, _ s: SyntheticSetup, first: SyntheticDay, columns: Int,
                         events: [SyntheticEvent], hourFrom: Int = 8, hourTo: Int = 18) -> SyntheticDrawing {
        let p = s.palette, clock24 = s.clock24 ?? true, lang = s.language
        let left = area.minX + 76, hourHeight = 64.0
        let columnWidth = (area.width - 76 - 16) / Double(columns)
        var y = area.minY + 12
        let last = first.adding(columns - 1)
        let title: String
        if columns == 1 {
            title = lang == .en ? "\(SyntheticWords.dayName(2, lang, short: false)), \(SyntheticWords.monthName(first.month, lang)) \(first.day), \(first.year)"
                                : "\(SyntheticWords.dayName(2, lang, short: false)), \(first.day) de \(SyntheticWords.monthName(first.month, lang)) de \(first.year)"
        } else {
            title = lang == .en ? "\(SyntheticWords.monthName(first.month, lang)) \(first.day) – \(last.day), \(first.year)"
                                : "\(first.day) – \(last.day) de \(SyntheticWords.monthName(first.month, lang)) de \(first.year)"
        }
        c.text(title, x: area.minX + 20, y: y, size: 22, color: p.text, bold: true)
        y += 40
        let dayOffset = 2
        for i in 0..<columns {
            let day = first.adding(i)
            let label = "\(SyntheticWords.dayName(columns == 1 ? dayOffset : i, lang, short: columns != 1)) \(day.day)"
            c.text(label, x: left + Double(i) * columnWidth + 10, y: y + 10, size: 16, color: p.text, bold: true)
        }
        c.fill(CGRect(x: area.minX, y: y + 38, width: area.width, height: 1), p.line)
        y += 40
        let allDay = events.filter(\.allDay)
        if !allDay.isEmpty {
            for e in allDay {
                let x = left + Double(e.day) * columnWidth + 4
                c.fillRounded(CGRect(x: x, y: y + 3, width: columnWidth - 8, height: 24), radius: 4, p.accent)
                c.text(e.title, x: x + 8, y: y + 7, size: 14, color: RGB(0xFFFFFF))
            }
            y += 32
            c.fill(CGRect(x: area.minX, y: y, width: area.width, height: 1), p.line)
        }
        let gridTop = y + 8
        for h in hourFrom...hourTo {
            let ly = gridTop + Double(h - hourFrom) * hourHeight
            c.fill(CGRect(x: left, y: ly, width: area.width - 76 - 16, height: 1), p.line)
            c.text(SyntheticWords.hourLabel(h, clock24: clock24), x: area.minX + 12, y: ly - 8, size: 14, color: p.muted)
        }
        for i in 0...columns { c.fill(CGRect(x: left + Double(i) * columnWidth, y: gridTop, width: 1, height: Double(hourTo - hourFrom) * hourHeight), p.line) }

        var findings: [ExpectedFinding] = []
        var colour = 0
        for e in events {
            let day = first.adding(e.day)
            if e.allDay {
                findings.append(ExpectedFinding(kind: "appointment", title: e.title, start: day.date(zone: s.zone), allDay: true, people: [], place: e.place))
                continue
            }
            let top = gridTop + (Double(e.hour - hourFrom) + Double(e.minute) / 60) * hourHeight + 1
            let height = Double(e.minutes) / 60 * hourHeight - 2
            let x = left + Double(e.day) * columnWidth + 4
            let pair = blockColours[colour % blockColours.count]; colour += 1
            c.fillRounded(CGRect(x: x, y: top, width: columnWidth - 8, height: height), radius: 4, p.dark ? pair.dark : pair.light)
            c.fill(CGRect(x: x, y: top, width: 4, height: height), p.accent)
            let time = SyntheticWords.clock(e.hour, e.minute, clock24: clock24)
            c.text("\(time) \(e.title)", x: x + 10, y: top + (height < 40 ? 6 : 5), size: 14, color: p.text, bold: true)
            if let place = e.place, e.minutes >= 60 { c.text(place, x: x + 10, y: top + 25, size: 13, color: p.muted) }
            let start = day.date(e.hour, e.minute, zone: s.zone)
            findings.append(ExpectedFinding(kind: "appointment", title: e.title, start: start, end: start.addingTimeInterval(Double(e.minutes) * 60),
                                            allDay: false, people: [], place: e.minutes >= 60 ? e.place : nil, inferred: ["end"]))
        }
        return SyntheticDrawing(kind: columns == 1 ? .calendarDay : .calendarWeek, findings: findings)
    }

    /// A month grid (Monday first, five rows). Chips show the start time and title; nothing shows an end.
    static func month(_ c: SyntheticCanvas, _ area: CGRect, _ s: SyntheticSetup, firstMonday: SyntheticDay, month: Int, year: Int,
                      events: [(day: SyntheticDay, event: SyntheticEvent)]) -> SyntheticDrawing {
        let p = s.palette, clock24 = s.clock24 ?? true, lang = s.language
        c.text("\(SyntheticWords.monthName(month, lang)) \(lang == .en ? "" : "de ")\(year)".replacingOccurrences(of: "  ", with: " "),
               x: area.minX + 20, y: area.minY + 12, size: 24, color: p.text, bold: true)
        let gridTop = area.minY + 100, rows = 5
        let cellW = (area.width - 32) / 7, cellH = (area.height - 100 - 12) / Double(rows)
        for i in 0..<7 {
            c.text(SyntheticWords.dayName(i, lang, short: true), x: area.minX + 16 + Double(i) * cellW + 8, y: area.minY + 66, size: 15, color: p.muted, bold: true)
        }
        for r in 0..<rows {
            for col in 0..<7 {
                let day = firstMonday.adding(r * 7 + col)
                let rect = CGRect(x: area.minX + 16 + Double(col) * cellW, y: gridTop + Double(r) * cellH, width: cellW, height: cellH)
                c.stroke(rect, p.line)
                c.text("\(day.day)", x: rect.minX + 8, y: rect.minY + 6, size: 15, color: day.month == month ? p.text : p.muted, bold: day.month == month)
            }
        }
        var findings: [ExpectedFinding] = []
        var perDay: [Int: Int] = [:]
        for (day, e) in events {
            let cellIndex = (0..<(rows * 7)).first { firstMonday.adding($0).day == day.day && firstMonday.adding($0).month == day.month }!
            let slot = perDay[cellIndex, default: 0]; perDay[cellIndex] = slot + 1
            let rect = CGRect(x: area.minX + 16 + Double(cellIndex % 7) * cellW + 6, y: gridTop + Double(cellIndex / 7) * cellH + 30 + Double(slot) * 28,
                              width: cellW - 12, height: 24)
            c.fillRounded(rect, radius: 4, e.allDay ? p.accent : (p.dark ? blockColours[0].dark : blockColours[0].light))
            if e.allDay {
                c.text(e.title, x: rect.minX + 8, y: rect.minY + 4, size: 14, color: RGB(0xFFFFFF))
                findings.append(ExpectedFinding(kind: "appointment", title: e.title, start: day.date(zone: s.zone), allDay: true, people: []))
            } else {
                let time = SyntheticWords.clock(e.hour, e.minute, clock24: clock24)
                c.text("\(time) \(e.title)", x: rect.minX + 8, y: rect.minY + 4, size: 14, color: p.text)
                let start = day.date(e.hour, e.minute, zone: s.zone)
                findings.append(ExpectedFinding(kind: "appointment", title: e.title, start: start, end: start.addingTimeInterval(3600),
                                                allDay: false, people: [], inferred: ["end"]))
            }
        }
        return SyntheticDrawing(kind: .calendarMonth, findings: findings)
    }

    // MARK: Cases

    private static let zoneNY = "America/New_York"
    private static let mac = "Europe/Madrid"

    static func cases() throws -> [SyntheticCase] {
        let monday = SyntheticDay(2026, 10, 12)
        let wednesday = SyntheticDay(2026, 10, 14)
        let capture = SyntheticTime.date(2026, 10, 14, 15, 0, zone: "UTC")
        var out: [SyntheticCase] = []

        // Week views
        var s = SyntheticSetup(name: "calendar-week-outlook-24h-blocks", look: .outlook, application: "Outlook", platform: "Windows",
                               palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture,
                               windowTitle: "Calendar - Customer A - Outlook", features: ["header-date", "block-30", "block-60", "block-90", "block-120"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Daily standup", day: 0, hour: 9, minute: 0, minutes: 30),
                SyntheticEvent(title: "Team sync", day: 1, hour: 10, minute: 0, minutes: 60, place: "Room 4"),
                SyntheticEvent(title: "Design review", day: 2, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                SyntheticEvent(title: "Quarterly planning", day: 3, hour: 14, minute: 0, minutes: 120, place: "Conference A"),
                SyntheticEvent(title: "Coffee with Sam", day: 4, hour: 11, minute: 30, minutes: 30),
            ])
        })

        s = SyntheticSetup(name: "calendar-week-web-12h", look: .web, application: "Web calendar", platform: "macOS", clock24: false,
                           palette: .light, zone: mac, capturedAt: capture, windowTitle: "Calendar", features: ["header-date", "block-60"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Dentist", day: 1, hour: 9, minute: 0, minutes: 60, place: "Clinic"),
                SyntheticEvent(title: "Project kickoff", day: 2, hour: 15, minute: 30, minutes: 60),
                SyntheticEvent(title: "Gym", day: 3, hour: 17, minute: 0, minutes: 60),
            ])
        })

        s = SyntheticSetup(name: "calendar-week-teams-dark-es", look: .teams, application: "Teams", platform: "Windows", language: .es,
                           palette: .dark, zone: mac, capturedAt: capture, windowTitle: "Calendario | Microsoft Teams", features: ["header-date", "block-90"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Revisión de diseño", day: 0, hour: 10, minute: 0, minutes: 90, place: "Sala 2"),
                SyntheticEvent(title: "Comida con Ana", day: 2, hour: 14, minute: 0, minutes: 60),
                SyntheticEvent(title: "Seguimiento", day: 4, hour: 9, minute: 30, minutes: 30),
            ])
        })

        s = SyntheticSetup(name: "calendar-week-remote-outlook-12h", look: .outlook, application: "Outlook", platform: "Windows", clock24: false,
                           palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture, remote: SyntheticRemote(client: "Citrix"),
                           windowTitle: "Calendar - Customer A - Outlook", features: ["header-date", "block-60", "block-120"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Vendor call", day: 1, hour: 11, minute: 0, minutes: 60, place: "Phone"),
                SyntheticEvent(title: "Workshop", day: 3, hour: 13, minute: 0, minutes: 120, place: "Room 12"),
            ], hourFrom: 8, hourTo: 17)
        })

        s = SyntheticSetup(name: "calendar-week-outlook-allday", look: .outlook, application: "Outlook", platform: "Windows",
                           palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture,
                           windowTitle: "Calendar - Customer A - Outlook", features: ["header-date", "block-60"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Company offsite", day: 3, hour: 0, minute: 0, minutes: 0, allDay: true),
                SyntheticEvent(title: "Board prep", day: 1, hour: 16, minute: 0, minutes: 60),
            ])
        })

        // Day views
        s = SyntheticSetup(name: "calendar-day-outlook-24h", look: .outlook, application: "Outlook", platform: "Windows",
                           palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture,
                           windowTitle: "Calendar - Customer A - Outlook", features: ["header-date", "block-30", "block-60", "block-90"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: wednesday, columns: 1, events: [
                SyntheticEvent(title: "Inbox zero", day: 0, hour: 8, minute: 30, minutes: 30),
                SyntheticEvent(title: "Architecture review", day: 0, hour: 10, minute: 0, minutes: 90, place: "Room 7"),
                SyntheticEvent(title: "Lunch with Priya", day: 0, hour: 12, minute: 30, minutes: 60, place: "Canteen"),
            ])
        })

        s = SyntheticSetup(name: "calendar-day-teams-es-24h", look: .teams, application: "Teams", platform: "Windows", language: .es,
                           palette: .dark, zone: mac, capturedAt: capture, windowTitle: "Calendario | Microsoft Teams", features: ["header-date", "block-60"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: wednesday, columns: 1, events: [
                SyntheticEvent(title: "Reunión de equipo", day: 0, hour: 9, minute: 0, minutes: 60, place: "Sala 1"),
                SyntheticEvent(title: "Llamada con cliente", day: 0, hour: 16, minute: 0, minutes: 60),
            ])
        })

        s = SyntheticSetup(name: "calendar-day-remote-web-12h", look: .web, application: "Web calendar", platform: "Linux", clock24: false,
                           palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture,
                           remote: SyntheticRemote(client: "Remote Desktop"), windowTitle: "Calendar", features: ["header-date", "block-30", "block-120"])
        out.append(try SyntheticChrome.make(s) { c, a in
            timeGrid(c, a, s, first: wednesday, columns: 1, events: [
                SyntheticEvent(title: "Stand-up", day: 0, hour: 9, minute: 0, minutes: 30),
                SyntheticEvent(title: "Sprint planning", day: 0, hour: 13, minute: 0, minutes: 120, place: "Room 3"),
            ], hourFrom: 8, hourTo: 16)
        })

        // Month views
        let sep28 = SyntheticDay(2026, 9, 28)
        s = SyntheticSetup(name: "calendar-month-web-24h", look: .web, application: "Web calendar", platform: "macOS",
                           palette: .light, zone: mac, capturedAt: capture, windowTitle: "Calendar", features: ["header-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            month(c, a, s, firstMonday: sep28, month: 10, year: 2026, events: [
                (SyntheticDay(2026, 10, 6), SyntheticEvent(title: "Budget meeting", day: 0, hour: 10, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 10, 14), SyntheticEvent(title: "Team sync", day: 0, hour: 15, minute: 30, minutes: 0)),
                (SyntheticDay(2026, 10, 14), SyntheticEvent(title: "Dinner", day: 0, hour: 20, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 10, 22), SyntheticEvent(title: "Conference", day: 0, hour: 0, minute: 0, minutes: 0, allDay: true)),
            ])
        })

        s = SyntheticSetup(name: "calendar-month-outlook-es", look: .outlook, application: "Outlook", platform: "Windows", language: .es,
                           palette: .light, zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture,
                           windowTitle: "Calendario - Customer A - Outlook", features: ["header-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            month(c, a, s, firstMonday: sep28, month: 10, year: 2026, events: [
                (SyntheticDay(2026, 10, 8), SyntheticEvent(title: "Revisión trimestral", day: 0, hour: 9, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 10, 19), SyntheticEvent(title: "Formación", day: 0, hour: 0, minute: 0, minutes: 0, allDay: true)),
                (SyntheticDay(2026, 10, 27), SyntheticEvent(title: "Cierre de mes", day: 0, hour: 17, minute: 0, minutes: 0)),
            ])
        })

        s = SyntheticSetup(name: "calendar-month-teams-dark-12h", look: .teams, application: "Teams", platform: "Windows", clock24: false,
                           palette: .dark, zone: mac, capturedAt: capture, windowTitle: "Calendar | Microsoft Teams", features: ["header-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            month(c, a, s, firstMonday: sep28, month: 10, year: 2026, events: [
                (SyntheticDay(2026, 10, 13), SyntheticEvent(title: "Sales review", day: 0, hour: 14, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 10, 20), SyntheticEvent(title: "Roadmap", day: 0, hour: 11, minute: 30, minutes: 0)),
            ])
        })

        // A month that is not the month of the capture: only its title (and the label of its first day) say which month it is, because
        // the same weekday grid fits other months too. A calendar left on an old month is common; reading it as the capture's month is not allowed.
        let jan26 = SyntheticDay(2026, 1, 26)
        s = SyntheticSetup(name: "calendar-month-other-month-es", look: .outlook, application: "Outlook", platform: "Windows", language: .es,
                           palette: .light, zone: mac, capturedAt: capture, windowTitle: "Calendario - Outlook", features: ["header-date", "other-month"])
        out.append(try SyntheticChrome.make(s) { c, a in
            month(c, a, s, firstMonday: jan26, month: 2, year: 2026, events: [
                (SyntheticDay(2026, 2, 3), SyntheticEvent(title: "Revisión de presupuesto", day: 0, hour: 10, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 2, 12), SyntheticEvent(title: "Reunión de equipo", day: 0, hour: 15, minute: 30, minutes: 0)),
                (SyntheticDay(2026, 2, 19), SyntheticEvent(title: "Formación", day: 0, hour: 0, minute: 0, minutes: 0, allDay: true)),
            ])
        })
        return out
    }
}
