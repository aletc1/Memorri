import CoreGraphics
import Foundation

/// A window of a drawn desktop: where it is, how far in front, and what it shows (nothing for a window that cannot hold appointments).
struct DesktopWindow {
    let app: String
    let bundle: String
    let title: String
    let frame: CGRect
    /// 0 is the window in front.
    let stack: Int
    let draw: ((SyntheticCanvas, CGRect) -> SyntheticDrawing)?
    var key: String { "w\(stack)" }
}

/// Drawn desktops with several overlapping windows, a menu bar and its clock (spec 011). The expected lines leave out what a window in
/// front covers, as a reader of the picture would; each expected finding names the window it is in.
enum SyntheticWindows {
    private static let mac = "Europe/Madrid"
    private static let size = (width: 2200, height: 1200)
    private static let titleBar = 36.0

    /// Draws the windows back to front on a wallpaper under a menu bar, and gathers what a reader should find.
    static func desktop(name: String, setup s: SyntheticSetup, clock: String, features: Set<String>, windows: [DesktopWindow]) throws -> SyntheticCase {
        let canvas = SyntheticCanvas(width: size.width, height: size.height, background: RGB(0x3B5B7F))
        canvas.fill(CGRect(x: 0, y: 0, width: Double(size.width), height: 28), RGB(0xE9E9E9))
        canvas.text("Finder", x: 20, y: 5, size: 15, color: RGB(0x1C1C1C), bold: true)
        canvas.text(clock, x: Double(size.width) - 20 - canvas.textWidth(clock, size: 15), y: 5, size: 15, color: RGB(0x1C1C1C))

        var drawn: [(window: DesktopWindow, lines: [ExpectedLine], drawing: SyntheticDrawing?)] = []
        for window in windows.sorted(by: { $0.stack > $1.stack }) {
            let p = s.palette
            let before = canvas.lines.count
            canvas.fill(window.frame, p.background)
            canvas.stroke(window.frame, p.line)
            canvas.fill(CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: titleBar), p.panel)
            for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                canvas.fillCircle(center: CGPoint(x: window.frame.minX + 22 + Double(i) * 22, y: window.frame.minY + titleBar / 2), radius: 6, RGB(UInt32(color)))
            }
            canvas.text(window.title, x: window.frame.minX + 100, y: window.frame.minY + 9, size: 15, color: p.text, bold: true)
            let content = CGRect(x: window.frame.minX, y: window.frame.minY + titleBar, width: window.frame.width, height: window.frame.height - titleBar)
            let drawing = window.draw?(canvas, content)
            drawn.append((window, Array(canvas.lines[before...]), drawing))
        }

        func covered(_ line: ExpectedLine, by front: [DesktopWindow]) -> Bool {
            guard let box = line.box, box.count == 4 else { return false }
            let x = Double(box[0]) + Double(box[2]) / 2, y = Double(box[1]) + Double(box[3]) / 2
            return front.contains { $0.frame.contains(CGPoint(x: x, y: y)) }
        }
        var lines: [ExpectedLine] = Array(canvas.lines[0..<(canvas.lines.count - drawn.reduce(0) { $0 + $1.lines.count })])
        var findings: [ExpectedFinding] = []
        for item in drawn.sorted(by: { $0.window.stack < $1.window.stack }) {
            let inFront = windows.filter { $0.stack < item.window.stack }
            lines += item.lines.filter { !covered($0, by: inFront) }
            findings += (item.drawing?.findings ?? []).map { $0.inWindow(item.window.key) }
        }
        let frontKind = drawn.filter { ($0.drawing?.kind ?? .other) != .other }.min { $0.window.stack < $1.window.stack }?.drawing?.kind ?? .other

        let tags = [ExpectedTag(key: "language", value: s.language.rawValue), ExpectedTag(key: "theme", value: s.palette.dark ? "dark" : "light")]
        let goldenWindows = windows.sorted { $0.stack < $1.stack }.map {
            GoldenWindow(app: $0.app, bundleID: $0.bundle, title: $0.title,
                         frame: [Int($0.frame.minX), Int($0.frame.minY), Int($0.frame.width), Int($0.frame.height)], stack: $0.stack)
        }
        let meta = GoldenMeta(capturedAt: s.capturedAt, macTimezone: s.macZone, context: nil, windows: goldenWindows,
                              displaySize: [size.width, size.height], scale: 1.0, origin: .synthetic)
        let expected = GoldenExpected(screenKind: frontKind.rawValue, tags: tags, context: nil, lines: lines, findings: findings)
        return SyntheticCase(name: name, meta: meta, expected: expected, picture: try canvas.pngData(),
                             features: features.union(["multi-window", "lang-\(s.language.rawValue)"]))
    }

    private static func setup(_ name: String) -> SyntheticSetup {
        SyntheticSetup(name: name, look: .plain, application: nil, platform: "macOS", palette: .mac, zone: mac,
                       capturedAt: SyntheticTime.date(2026, 10, 14, 9, 12, zone: mac), windowTitle: "Desktop", size: size)
    }

    private static let clock = "Wed 14 Oct 09:12"

    static func cases() throws -> [SyntheticCase] {
        var out: [SyntheticCase] = []
        let monday = SyntheticDay(2026, 10, 12), wednesday = SyntheticDay(2026, 10, 14)

        // A calendar beside a mail: items from both, each dated by its own window ("tomorrow" is in the mail, a week header in the calendar).
        var s = setup("windows-calendar-and-mail")
        out.append(try desktop(name: s.name, setup: s, clock: clock, features: ["header-date", "relative-date", "block-60", "block-90"], windows: [
            DesktopWindow(app: "Mail", bundle: "com.apple.mail", title: "Inbox", frame: CGRect(x: 1280, y: 60, width: 900, height: 760), stack: 0, draw: { c, a in
                SyntheticMessages.email(c, a, s, others: [("Finance", "Invoice 4471", "Attached is the invoice for"), ("HR team", "Benefits update", "Open enrolment starts soon"),
                                                          ("IT support", "Password expiry", "Your password will expire")],
                                        from: "Laura Gómez", subject: "Planning meeting", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                                        body: ["Hi team,", "Planning meeting: tomorrow at 10:00.", "Please bring the budget.", "Laura"],
                                        findings: [ExpectedFinding(kind: "appointment", title: "Planning meeting", start: SyntheticTime.date(2026, 10, 15, 10, 0, zone: mac),
                                                                   end: SyntheticTime.date(2026, 10, 15, 11, 0, zone: mac), allDay: false, people: [], inferred: ["end"])])
            }),
            DesktopWindow(app: "Calendar", bundle: "com.apple.iCal", title: "Calendar", frame: CGRect(x: 20, y: 60, width: 1240, height: 760), stack: 1, draw: { c, a in
                SyntheticCalendars.timeGrid(c, a, s, first: monday, columns: 5, events: [
                    SyntheticEvent(title: "Daily standup", day: 0, hour: 9, minute: 0, minutes: 30),
                    SyntheticEvent(title: "Design review", day: 2, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                    SyntheticEvent(title: "Coffee with Sam", day: 4, hour: 11, minute: 30, minutes: 60),
                ], hourFrom: 8, hourTo: 16)
            }),
        ]))

        // A calendar left on March, half under a browser full of dates and numbers (and an October heading): only the visible columns count,
        // and the browser's text names no month for the calendar.
        s = setup("windows-calendar-under-browser")
        let march = SyntheticDay(2026, 3, 9)
        out.append(try desktop(name: s.name, setup: s, clock: clock, features: ["header-date", "other-month", "block-30", "block-60", "block-90"], windows: [
            DesktopWindow(app: "Safari", bundle: "com.apple.Safari", title: "Quarterly report", frame: CGRect(x: 940, y: 100, width: 1240, height: 900), stack: 0, draw: { c, a in
                let p = s.palette
                c.fill(CGRect(x: a.minX, y: a.minY, width: a.width, height: 44), p.panel)
                c.text("https://reports.example.com/quarterly", x: a.minX + 20, y: a.minY + 12, size: 15, color: p.muted)
                c.text("Quarterly revenue report - October 2026", x: a.minX + 40, y: a.minY + 80, size: 28, color: p.text, bold: true)
                let rows = [("Sep 30, 2026", "Revenue", "1,250,400"), ("Oct 1, 2026", "Forecast", "1,310,000"), ("Oct 14, 2026", "Actual", "1,287,950"),
                            ("Oct 21, 2026", "Forecast", "1,402,300"), ("Oct 28, 2026", "Forecast", "1,455,000"), ("Nov 4, 2026", "Forecast", "1,512,750"),
                            ("Nov 11, 2026", "Forecast", "1,560,100"), ("Nov 18, 2026", "Forecast", "1,611,420")]
                for (i, row) in rows.enumerated() {
                    let y = a.minY + 160 + Double(i) * 44
                    c.text(row.0, x: a.minX + 60, y: y, size: 19, color: p.text)
                    c.text(row.1, x: a.minX + 330, y: y, size: 19, color: p.text)
                    c.text(row.2, x: a.minX + 560, y: y, size: 19, color: p.text)
                }
                return SyntheticDrawing(kind: .other, findings: [])
            }),
            DesktopWindow(app: "Calendar", bundle: "com.apple.iCal", title: "Calendar", frame: CGRect(x: 20, y: 60, width: 1500, height: 760), stack: 1, draw: { c, a in
                SyntheticCalendars.timeGrid(c, a, s, first: march, columns: 5, events: [
                    SyntheticEvent(title: "Daily standup", day: 0, hour: 9, minute: 0, minutes: 30),
                    SyntheticEvent(title: "Team sync", day: 1, hour: 10, minute: 0, minutes: 60, place: "Room 4"),
                    SyntheticEvent(title: "Design review", day: 2, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                ], hourFrom: 8, hourTo: 16)
            }),
        ]))

        // The same appointment in a week view and in a day view of two calendar windows: two sightings of one event.
        s = setup("windows-two-calendars-same-event")
        out.append(try desktop(name: s.name, setup: s, clock: clock, features: ["header-date", "block-30", "block-90", "same-event-twice"], windows: [
            DesktopWindow(app: "Calendar", bundle: "com.apple.iCal", title: "Calendar - Day", frame: CGRect(x: 1280, y: 60, width: 900, height: 760), stack: 0, draw: { c, a in
                SyntheticCalendars.timeGrid(c, a, s, first: wednesday, columns: 1, events: [
                    SyntheticEvent(title: "Inbox zero", day: 0, hour: 8, minute: 30, minutes: 30),
                    SyntheticEvent(title: "Design review", day: 0, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                ], hourFrom: 8, hourTo: 16)
            }),
            DesktopWindow(app: "Calendar", bundle: "com.apple.iCal", title: "Calendar - Week", frame: CGRect(x: 20, y: 60, width: 1240, height: 760), stack: 1, draw: { c, a in
                SyntheticCalendars.timeGrid(c, a, s, first: monday, columns: 5, events: [
                    SyntheticEvent(title: "Daily standup", day: 0, hour: 9, minute: 0, minutes: 30),
                    SyntheticEvent(title: "Design review", day: 2, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                ], hourFrom: 8, hourTo: 16)
            }),
        ]))

        // A month view left on February, beside a mail, under a menu-bar clock of October: the month comes from the calendar's own title, never
        // from the capture or the clock, and the grid is read without a model call.
        s = setup("windows-month-other-month-menu-clock")
        let jan26 = SyntheticDay(2026, 1, 26)
        out.append(try desktop(name: s.name, setup: s, clock: clock, features: ["header-date", "other-month", "relative-date"], windows: [
            DesktopWindow(app: "Mail", bundle: "com.apple.mail", title: "Inbox", frame: CGRect(x: 1280, y: 60, width: 900, height: 760), stack: 0, draw: { c, a in
                SyntheticMessages.email(c, a, s, others: [("Finance", "Invoice 4471", "Attached is the invoice for"), ("HR team", "Benefits update", "Open enrolment starts soon"),
                                                          ("IT support", "Password expiry", "Your password will expire")],
                                        from: "Laura Gómez", subject: "Contract review", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                                        body: ["Hi team,", "Contract review: Friday 16 October at 14:00.", "Please read it before.", "Laura"],
                                        findings: [ExpectedFinding(kind: "appointment", title: "Contract review", start: SyntheticTime.date(2026, 10, 16, 14, 0, zone: mac),
                                                                   end: SyntheticTime.date(2026, 10, 16, 15, 0, zone: mac), allDay: false, people: [], inferred: ["end"])])
            }),
            DesktopWindow(app: "Calendar", bundle: "com.apple.iCal", title: "Calendar", frame: CGRect(x: 20, y: 60, width: 1240, height: 760), stack: 1, draw: { c, a in
                SyntheticCalendars.month(c, a, s, firstMonday: jan26, month: 2, year: 2026, events: [
                    (SyntheticDay(2026, 2, 3), SyntheticEvent(title: "Budget review", day: 0, hour: 10, minute: 0, minutes: 0)),
                    (SyntheticDay(2026, 2, 12), SyntheticEvent(title: "Team sync", day: 0, hour: 15, minute: 30, minutes: 0)),
                    (SyntheticDay(2026, 2, 19), SyntheticEvent(title: "Training", day: 0, hour: 0, minute: 0, minutes: 0, allDay: true)),
                ])
            }),
        ]))

        // A remote desktop whose own clock (Tokyo, taskbar at the bottom) is already the next day: "tomorrow" in its chat is the day after that, not
        // the day after the Mac's date. The Mac's menu bar clock is the capture's.
        s = setup("windows-remote-clock-other-zone")
        s.capturedAt = SyntheticTime.date(2026, 10, 14, 20, 30, zone: mac)
        out.append(try desktop(name: s.name, setup: s, clock: "Wed 14 Oct 20:30", features: ["relative-date", "remote-frame", "remote-clock", "text-only-no-end"], windows: [
            DesktopWindow(app: "Microsoft Remote Desktop", bundle: "com.microsoft.rdc.macos", title: "Remote Desktop Connection - Customer A",
                          frame: CGRect(x: 520, y: 60, width: 1660, height: 1060), stack: 0, draw: { c, a in
                let taskbar = CGRect(x: a.minX, y: a.maxY - 40, width: a.width, height: 40)
                let desk = CGRect(x: a.minX, y: a.minY, width: a.width, height: a.height - 40)
                let drawing = SyntheticMessages.chat(c, desk, s, contact: "Anna Schmidt", separator: "Today",
                                                     messages: [SyntheticMessage(name: "Anna Schmidt", time: "03:12", text: "Morning! Did you see the notes?"),
                                                                SyntheticMessage(name: "Ben Ortiz", time: "03:28", text: "Can we meet tomorrow at 10:00?"),
                                                                SyntheticMessage(name: "Anna Schmidt", time: "03:29", text: "Sounds good, thanks.")],
                                                     findings: [ExpectedFinding(kind: "appointment", title: "Meeting", start: SyntheticTime.date(2026, 10, 16, 10, 0, zone: mac),
                                                                                end: SyntheticTime.date(2026, 10, 16, 11, 0, zone: mac), allDay: false, people: [], inferred: ["end"])])
                c.fill(taskbar, RGB(0x1B1B1B))
                let remoteClock = "Thu 15 Oct 03:30"
                c.text(remoteClock, x: taskbar.maxX - 24 - c.textWidth(remoteClock, size: 16), y: taskbar.minY + 11, size: 16, color: RGB(0xFFFFFF))
                return drawing
            }),
            // A note beside it, that says nothing the remote desktop's clock should be read for.
            DesktopWindow(app: "Notes", bundle: "com.apple.Notes", title: "Notes", frame: CGRect(x: 20, y: 60, width: 480, height: 700), stack: 1, draw: { c, a in
                let p = s.palette
                for (i, text) in ["Shopping list", "milk", "bread", "coffee", "Plumber was here Friday"].enumerated() {
                    c.text(text, x: a.minX + 24, y: a.minY + 24 + Double(i) * 36, size: 18, color: p.text, bold: i == 0)
                }
                return SyntheticDrawing(kind: .other, findings: [])
            }),
        ]))
        return out
    }
}
