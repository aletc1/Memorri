import CoreGraphics
import Foundation

/// Drawn window captures (spec 013): a picture of one window and nothing else, with no menu bar and no desktop around it, as the window capture takes it.
/// Each case's `meta.json` says `scope: window` and lists the one window, which fills the picture; every expected finding names it (`w0`).
enum SyntheticWindowCaptures {
    private static let mac = "Europe/Madrid"
    private static let titleBar = 36.0

    /// Draws the window's title bar and hands the rest of the picture to `draw`. `overlay` draws something over the window afterwards (a panel that
    /// floats over it); the expected lines leave out what the overlay covers.
    static func picture(name: String, setup s: SyntheticSetup, size: (width: Int, height: Int), app: String, bundle: String, title: String,
                        features: Set<String>, draw: (SyntheticCanvas, CGRect) -> SyntheticDrawing,
                        overlay: ((SyntheticCanvas, CGRect) -> CGRect)? = nil) throws -> SyntheticCase {
        let p = s.palette
        let canvas = SyntheticCanvas(width: size.width, height: size.height, background: p.background)
        canvas.fill(CGRect(x: 0, y: 0, width: Double(size.width), height: titleBar), p.panel)
        for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            canvas.fillCircle(center: CGPoint(x: 22 + Double(i) * 22, y: titleBar / 2), radius: 6, RGB(UInt32(color)))
        }
        canvas.text(title, x: 100, y: 9, size: 15, color: p.text, bold: true)
        let content = CGRect(x: 0, y: titleBar, width: Double(size.width), height: Double(size.height) - titleBar)
        let drawing = draw(canvas, content)

        var lines = canvas.lines
        if let overlay {
            let before = canvas.lines.count
            let covered = overlay(canvas, content)
            let added = Array(canvas.lines[before...])
            lines = lines[0..<before].filter { line in
                guard let box = line.box, box.count == 4 else { return true }
                return !covered.contains(CGPoint(x: Double(box[0]) + Double(box[2]) / 2, y: Double(box[1]) + Double(box[3]) / 2))
            } + added
        }

        let tags = [ExpectedTag(key: "language", value: s.language.rawValue), ExpectedTag(key: "theme", value: p.dark ? "dark" : "light")]
        let meta = GoldenMeta(capturedAt: s.capturedAt, macTimezone: s.macZone, context: s.context,
                              windows: [GoldenWindow(app: app, bundleID: bundle, title: title, frame: [0, 0, size.width, size.height], stack: 0)],
                              displaySize: [size.width, size.height], scale: 1.0, origin: .synthetic, scope: .window)
        let expected = GoldenExpected(screenKind: drawing.kind.rawValue, tags: tags, context: s.context?.name, lines: lines,
                                      findings: drawing.findings.map { $0.inWindow("w0") })
        return SyntheticCase(name: name, meta: meta, expected: expected, picture: try canvas.pngData(),
                             features: features.union(["window-capture", "lang-\(s.language.rawValue)"]))
    }

    private static func setup(_ name: String, size: (width: Int, height: Int)) -> SyntheticSetup {
        SyntheticSetup(name: name, look: .plain, application: nil, platform: "macOS", palette: .mac, zone: mac,
                       capturedAt: SyntheticTime.date(2026, 10, 14, 9, 12, zone: mac), windowTitle: "Window", size: size)
    }

    static func cases() throws -> [SyntheticCase] {
        var out: [SyntheticCase] = []
        let monday = SyntheticDay(2026, 10, 12)

        // A mail on its own: "tomorrow" is the day after the mail's own date line; there is no menu bar clock to read.
        let mailSize = (width: 1100, height: 760)
        var s = setup("window-capture-mail", size: mailSize)
        out.append(try picture(name: s.name, setup: s, size: mailSize, app: "Mail", bundle: "com.apple.mail", title: "Inbox", features: ["relative-date"]) { c, a in
            SyntheticMessages.email(c, a, s, others: [("Finance", "Invoice 4471", "Attached is the invoice for"), ("HR team", "Benefits update", "Open enrolment starts soon"),
                                                      ("IT support", "Password expiry", "Your password will expire")],
                                    from: "Laura Gómez", subject: "Planning meeting", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                                    body: ["Hi team,", "Planning meeting: tomorrow at 10:00.", "See you there.", "Laura"],
                                    findings: [ExpectedFinding(kind: "appointment", title: "Planning meeting", start: SyntheticTime.date(2026, 10, 15, 10, 0, zone: mac),
                                                               end: SyntheticTime.date(2026, 10, 15, 11, 0, zone: mac), allDay: false, people: [], inferred: ["end"])])
        })

        // A month view left on February: the month comes from the calendar's own title, never from the capture time, and the grid is read without a model call.
        let monthSize = (width: 1240, height: 796)
        s = setup("window-capture-month-other-month", size: monthSize)
        let jan26 = SyntheticDay(2026, 1, 26)
        out.append(try picture(name: s.name, setup: s, size: monthSize, app: "Calendar", bundle: "com.apple.iCal", title: "Calendar",
                               features: ["header-date", "other-month"]) { c, a in
            SyntheticCalendars.month(c, a, s, firstMonday: jan26, month: 2, year: 2026, events: [
                (SyntheticDay(2026, 2, 3), SyntheticEvent(title: "Budget review", day: 0, hour: 10, minute: 0, minutes: 0)),
                (SyntheticDay(2026, 2, 12), SyntheticEvent(title: "Team sync", day: 0, hour: 15, minute: 30, minutes: 0)),
                (SyntheticDay(2026, 2, 19), SyntheticEvent(title: "Training", day: 0, hour: 0, minute: 0, minutes: 0, allDay: true)),
            ])
        })

        // A remote desktop window with its own taskbar clock (New York, already the next day): "tomorrow" in its chat is read against that clock.
        let remoteSize = (width: 1660, height: 1060)
        s = setup("window-capture-remote-clock", size: remoteSize)
        s.capturedAt = SyntheticTime.date(2026, 10, 14, 20, 30, zone: mac)
        s.context = SyntheticChrome.customerA
        s.zone = "America/New_York"
        out.append(try picture(name: s.name, setup: s, size: remoteSize, app: "Microsoft Remote Desktop", bundle: "com.microsoft.rdc.macos",
                               title: "Remote Desktop Connection - Customer A", features: ["relative-date", "remote-frame", "remote-clock", "text-only-no-end"]) { c, a in
            let taskbar = CGRect(x: a.minX, y: a.maxY - 40, width: a.width, height: 40)
            let desk = CGRect(x: a.minX, y: a.minY, width: a.width, height: a.height - 40)
            let drawing = SyntheticMessages.chat(c, desk, s, contact: "Anna Schmidt", separator: "Today",
                                                 messages: [SyntheticMessage(name: "Anna Schmidt", time: "03:12", text: "Morning! Did you see the notes?"),
                                                            SyntheticMessage(name: "Ben Ortiz", time: "03:28", text: "Planning meeting tomorrow at 10:00, can you join?"),
                                                            SyntheticMessage(name: "Anna Schmidt", time: "03:29", text: "Sounds good, thanks.")],
                                                 findings: [ExpectedFinding(kind: "appointment", title: "Planning meeting", start: SyntheticTime.date(2026, 10, 16, 10, 0, zone: "America/New_York"),
                                                                            end: SyntheticTime.date(2026, 10, 16, 11, 0, zone: "America/New_York"), allDay: false, people: [], inferred: ["end"])])
            c.fill(taskbar, RGB(0x1B1B1B))
            let remoteClock = "Thu 15 Oct 03:30"
            c.text(remoteClock, x: taskbar.maxX - 24 - c.textWidth(remoteClock, size: 16), y: taskbar.minY + 11, size: 16, color: RGB(0xFFFFFF))
            return drawing
        })

        // A week calendar with a small panel floating over an empty corner: the picture shows the panel, the entries outside it are found, and the panel's
        // text gives no item.
        let weekSize = (width: 1240, height: 796)
        s = setup("window-capture-covered", size: weekSize)
        out.append(try picture(name: s.name, setup: s, size: weekSize, app: "Calendar", bundle: "com.apple.iCal", title: "Calendar",
                               features: ["header-date", "block-30", "block-90", "covered-corner"], draw: { c, a in
            SyntheticCalendars.timeGrid(c, a, s, first: monday, columns: 5, events: [
                SyntheticEvent(title: "Daily standup", day: 0, hour: 9, minute: 0, minutes: 30),
                SyntheticEvent(title: "Design review", day: 2, hour: 13, minute: 0, minutes: 90, place: "Board room"),
                SyntheticEvent(title: "Coffee with Sam", day: 4, hour: 11, minute: 30, minutes: 60),
            ], hourFrom: 8, hourTo: 16)
        }, overlay: { c, a in
            let p = s.palette
            let panel = CGRect(x: a.maxX - 330, y: a.maxY - 190, width: 300, height: 160)
            c.fill(panel, p.panel)
            c.stroke(panel, p.line, width: 2)
            for (i, text) in ["Battery", "Charged 84%", "Wi-Fi: Office"].enumerated() {
                c.text(text, x: panel.minX + 20, y: panel.minY + 20 + Double(i) * 40, size: 18, color: p.text, bold: i == 0)
            }
            return panel
        }))

        // A terminal: nothing in it holds an appointment, a task or a reminder. It is read all the same and gives no item.
        let terminalSize = (width: 900, height: 600)
        s = setup("window-capture-terminal", size: terminalSize)
        out.append(try picture(name: s.name, setup: s, size: terminalSize, app: "Terminal", bundle: "com.apple.Terminal", title: "zsh - 80x24", features: ["no-findings"]) { c, a in
            c.fill(a, RGB(0x1E1E1E))
            let output = ["$ make build", "Compiling module Core", "Compiling module Storage", "Linking executable", "Build succeeded", "$ make test",
                          "Running 420 tests", "All tests passed", "$ git status", "On branch main", "nothing to commit, working tree clean"]
            for (i, text) in output.enumerated() {
                c.text(text, x: a.minX + 20, y: a.minY + 20 + Double(i) * 30, size: 18, color: RGB(0xD8D8D8))
            }
            return SyntheticDrawing(kind: .other, findings: [])
        })
        return out
    }
}
