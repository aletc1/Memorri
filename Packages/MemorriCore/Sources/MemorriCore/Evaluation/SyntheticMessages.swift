import CoreGraphics
import Foundation

struct SyntheticMessage: Sendable {
    let name: String
    let time: String
    let text: String
}

enum SyntheticMessages {
    private static let mac = "Europe/Madrid"
    private static let zoneNY = "America/New_York"

    // MARK: Drawings

    /// A message list on the left and the open message on the right.
    static func email(_ c: SyntheticCanvas, _ a: CGRect, _ s: SyntheticSetup, others: [(sender: String, subject: String, preview: String)],
                      from: String, subject: String, dateLine: String, body: [String], findings: [ExpectedFinding]) -> SyntheticDrawing {
        let p = s.palette
        c.fill(CGRect(x: a.minX, y: a.minY, width: 460, height: a.height), p.panel)
        c.fill(CGRect(x: a.minX + 460, y: a.minY, width: 1, height: a.height), p.line)
        var rows = others
        rows.insert((from, subject, body.first ?? ""), at: 1)
        for (i, row) in rows.enumerated() {
            let top = a.minY + Double(i) * 92
            if i == 1 { c.fill(CGRect(x: a.minX, y: top, width: 460, height: 92), p.dark ? RGB(0x3A3A3A) : RGB(0xD6E6FA)) }
            c.text(row.sender, x: a.minX + 20, y: top + 10, size: 16, color: p.text, bold: true)
            c.text(row.subject, x: a.minX + 20, y: top + 34, size: 15, color: p.text)
            c.text(String(row.preview.prefix(34)), x: a.minX + 20, y: top + 58, size: 14, color: p.muted)
            c.fill(CGRect(x: a.minX + 20, y: top + 91, width: 420, height: 1), p.line)
        }
        let x = a.minX + 500
        c.text(subject, x: x, y: a.minY + 28, size: 28, color: p.text, bold: true)
        c.text("From: \(from)", x: x, y: a.minY + 78, size: 16, color: p.muted)
        c.text(s.language == .en ? "To: me" : "Para: yo", x: x, y: a.minY + 102, size: 16, color: p.muted)
        c.text(dateLine, x: x, y: a.minY + 126, size: 16, color: p.muted)
        c.fill(CGRect(x: x, y: a.minY + 160, width: a.width - 540, height: 1), p.line)
        for (i, line) in body.enumerated() { c.text(line, x: x, y: a.minY + 190 + Double(i) * 34, size: 19, color: p.text) }
        return SyntheticDrawing(kind: .email, findings: findings)
    }

    /// A contact list on the left and a conversation on the right.
    static func chat(_ c: SyntheticCanvas, _ a: CGRect, _ s: SyntheticSetup, contact: String, separator: String,
                     messages: [SyntheticMessage], findings: [ExpectedFinding]) -> SyntheticDrawing {
        let p = s.palette
        c.fill(CGRect(x: a.minX, y: a.minY, width: 320, height: a.height), p.panel)
        c.fill(CGRect(x: a.minX + 320, y: a.minY, width: 1, height: a.height), p.line)
        for (i, name) in ["Anna Schmidt", "Design team", "Carlos Ruiz", "Release channel"].enumerated() {
            let top = a.minY + 16 + Double(i) * 64
            c.fillCircle(center: CGPoint(x: a.minX + 36, y: top + 24), radius: 18, p.accent)
            c.text(name, x: a.minX + 68, y: top + 14, size: 16, color: p.text, bold: i == 0)
        }
        let x = a.minX + 360
        c.text(contact, x: x, y: a.minY + 20, size: 22, color: p.text, bold: true)
        c.fill(CGRect(x: x, y: a.minY + 62, width: a.width - 380, height: 1), p.line)
        c.text(separator, x: x + (a.width - 380) / 2 - 60, y: a.minY + 80, size: 14, color: p.muted)
        for (i, m) in messages.enumerated() {
            let top = a.minY + 130 + Double(i) * 96
            c.fillCircle(center: CGPoint(x: x + 22, y: top + 22), radius: 18, p.accent)
            let box = c.text(m.name, x: x + 56, y: top, size: 16, color: p.text, bold: true)
            c.text(m.time, x: box.maxX + 12, y: top + 2, size: 14, color: p.muted)
            c.text(m.text, x: x + 56, y: top + 28, size: 18, color: p.text)
        }
        return SyntheticDrawing(kind: .chat, findings: findings)
    }

    /// A page of text on a grey desk.
    static func document(_ c: SyntheticCanvas, _ a: CGRect, _ s: SyntheticSetup, heading: String, paragraphs: [String],
                         findings: [ExpectedFinding]) -> SyntheticDrawing {
        let p = s.palette
        c.fill(a, p.panel)
        let page = CGRect(x: a.minX + 260, y: a.minY + 24, width: 1080, height: a.height - 24)
        c.fill(page, RGB(0xFFFFFF))
        c.stroke(page, p.line)
        c.text(heading, x: page.minX + 70, y: page.minY + 60, size: 34, color: RGB(0x1F1F1F), bold: true)
        for (i, line) in paragraphs.enumerated() {
            c.text(line, x: page.minX + 70, y: page.minY + 140 + Double(i) * 38, size: 19, color: RGB(0x1F1F1F))
        }
        return SyntheticDrawing(kind: .document, findings: findings)
    }

    // MARK: Cases

    private static func task(_ title: String, due: Date, people: [String] = [], remind: Date? = nil, kind: String = "task") -> ExpectedFinding {
        ExpectedFinding(kind: kind, title: title, due: due, remind: remind, allDay: true, people: people,
                        inferred: remind == nil ? nil : ["remind"])
    }

    static func cases() throws -> [SyntheticCase] {
        var out: [SyntheticCase] = []
        let capture = SyntheticTime.date(2026, 10, 14, 7, 12, zone: "UTC")   // 09:12 in Madrid, 03:12 in New York
        let inbox: [(sender: String, subject: String, preview: String)] = [
            ("Finance", "Invoice 4471", "Attached is the invoice for"), ("HR team", "Benefits update", "Open enrolment starts soon"),
            ("IT support", "Password expiry", "Your password will expire"), ("Newsletter", "Weekly digest", "Top stories this week"),
        ]

        let bandeja: [(sender: String, subject: String, preview: String)] = [
            ("Finanzas", "Factura 4471", "Adjunto la factura de"), ("Recursos Humanos", "Novedades de beneficios", "Pronto empieza la inscripción"),
            ("Soporte TI", "Caducidad de contraseña", "Su contraseña va a caducar"), ("Boletín", "Resumen semanal", "Las noticias de esta semana"),
        ]

        // Email
        var s = SyntheticSetup(name: "email-apple-mail-invite", look: .appleMail, application: "Apple Mail", platform: "macOS", palette: .mac,
                               zone: mac, capturedAt: capture, windowTitle: "Inbox", features: [])
        out.append(try SyntheticChrome.make(s) { c, a in
            email(c, a, s, others: inbox, from: "Laura Gómez", subject: "Project review", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                  body: ["Hi team,", "Project review: Thursday, 15 October 2026, 14:00-15:00 in Room 4.", "Please confirm your attendance.", "Laura"],
                  findings: [ExpectedFinding(kind: "appointment", title: "Project review", start: SyntheticTime.date(2026, 10, 15, 14, 0, zone: mac),
                                             end: SyntheticTime.date(2026, 10, 15, 15, 0, zone: mac), allDay: false, people: [], place: "Room 4")])
        })

        s = SyntheticSetup(name: "email-apple-mail-relative", look: .appleMail, application: "Apple Mail", platform: "macOS", clock24: nil,
                           palette: .mac, zone: mac, capturedAt: capture, windowTitle: "Inbox", features: ["relative-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            email(c, a, s, others: inbox, from: "Jon Reyes", subject: "Report", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                  body: ["Hi,", "Please send me the report by tomorrow.", "Thanks,", "Jon"],
                  findings: [task("Send the report", due: SyntheticTime.date(2026, 10, 15, zone: mac))])
        })

        s = SyntheticSetup(name: "email-web-x-needs-y", look: .web, application: "Web mail", platform: "macOS", clock24: nil, palette: .light,
                           zone: mac, capturedAt: capture, windowTitle: "Inbox - Mail", features: ["x-needs-y"])
        out.append(try SyntheticChrome.make(s) { c, a in
            email(c, a, s, others: inbox, from: "Ines Duarte", subject: "Budget", dateLine: "Date: Wednesday, 14 October 2026 at 09:12",
                  body: ["Hello,", "Maria needs the budget figures by Friday 23 October.", "Thank you,", "Ines"],
                  findings: [task("Budget figures", due: SyntheticTime.date(2026, 10, 23, zone: mac), people: ["Maria"])])
        })

        s = SyntheticSetup(name: "email-outlook-deadline", look: .outlook, application: "Outlook", platform: "Windows", clock24: nil, palette: .light,
                           zone: zoneNY, context: SyntheticChrome.customerA, capturedAt: capture, windowTitle: "Inbox - Customer A - Outlook",
                           features: ["deadline"])
        out.append(try SyntheticChrome.make(s) { c, a in
            email(c, a, s, others: inbox, from: "Dana Whitfield", subject: "Expense report", dateLine: "Date: Wed 10/14/2026 3:12 AM",
                  body: ["Hi all,", "The expense report must be submitted by Friday 30 October 2026.", "Regards,", "Dana"],
                  findings: [task("Submit the expense report", due: SyntheticTime.date(2026, 10, 30, zone: zoneNY),
                                  remind: SyntheticTime.date(2026, 10, 29, 9, 0, zone: zoneNY), kind: "deadline")])
        })

        s = SyntheticSetup(name: "email-web-es-relative", look: .web, application: "Web mail", platform: "macOS", language: .es, clock24: nil,
                           palette: .light, zone: mac, capturedAt: capture, windowTitle: "Bandeja de entrada - Correo", features: ["relative-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            email(c, a, s, others: bandeja, from: "Marta Vidal", subject: "Informe", dateLine: "Fecha: miércoles, 14 de octubre de 2026, 09:12",
                  body: ["Hola,", "Necesito el informe para el viernes.", "Gracias,", "Marta"],
                  findings: [task("Informe", due: SyntheticTime.date(2026, 10, 16, zone: mac))])
        })

        // Chat
        let chatHistory = { (text: String, name: String, time: String) -> [SyntheticMessage] in
            [SyntheticMessage(name: "Anna Schmidt", time: time, text: "Morning! Did you see the notes?"),
             SyntheticMessage(name: name, time: time, text: text),
             SyntheticMessage(name: "Anna Schmidt", time: time, text: "Sounds good, thanks.")]
        }
        s = SyntheticSetup(name: "chat-teams-tomorrow", look: .teams, application: "Teams", platform: "Windows", palette: .dark, zone: mac,
                           capturedAt: SyntheticTime.date(2026, 10, 14, 9, 50, zone: "UTC"), windowTitle: "Chat | Microsoft Teams",
                           features: ["relative-date", "text-only-no-end"])
        out.append(try SyntheticChrome.make(s) { c, a in
            let start = SyntheticTime.date(2026, 10, 15, 10, 0, zone: mac)
            return chat(c, a, s, contact: "Anna Schmidt", separator: "Today", messages: chatHistory("Can we meet tomorrow at 10:00?", "Ben Ortiz", "11:48"),
                        findings: [ExpectedFinding(kind: "appointment", title: "Meeting", start: start, end: start.addingTimeInterval(3600), allDay: false,
                                                   people: [], inferred: ["end"])])
        })

        s = SyntheticSetup(name: "chat-teams-midnight-zone", look: .teams, application: "Teams", platform: "Windows", palette: .dark, zone: zoneNY,
                           context: SyntheticChrome.customerA, capturedAt: SyntheticTime.date(2026, 10, 14, 23, 40, zone: "UTC"),
                           windowTitle: "Chat | Customer A | Microsoft Teams", features: ["relative-date", "text-only-no-end", "midnight-other-zone"])
        out.append(try SyntheticChrome.make(s) { c, a in
            let start = SyntheticTime.date(2026, 10, 15, 9, 0, zone: zoneNY)
            return chat(c, a, s, contact: "Anna Schmidt", separator: "Today", messages: chatHistory("Let's sync tomorrow at 9:00.", "Ben Ortiz", "19:38"),
                        findings: [ExpectedFinding(kind: "appointment", title: "Sync", start: start, end: start.addingTimeInterval(3600), allDay: false,
                                                   people: [], inferred: ["end"])])
        })

        s = SyntheticSetup(name: "chat-teams-es-tomorrow", look: .teams, application: "Teams", platform: "Windows", language: .es, palette: .dark,
                           zone: mac, capturedAt: SyntheticTime.date(2026, 10, 14, 9, 50, zone: "UTC"), windowTitle: "Chat | Microsoft Teams",
                           features: ["relative-date", "text-only-no-end"])
        out.append(try SyntheticChrome.make(s) { c, a in
            let start = SyntheticTime.date(2026, 10, 15, 15, 0, zone: mac)
            let history = [SyntheticMessage(name: "Anna Schmidt", time: "11:45", text: "Buenos días, ¿has visto las notas?"),
                           SyntheticMessage(name: "Ben Ortiz", time: "11:48", text: "¿Quedamos mañana a las 15:00?"),
                           SyntheticMessage(name: "Anna Schmidt", time: "11:49", text: "Perfecto, gracias.")]
            return chat(c, a, s, contact: "Anna Schmidt", separator: "Hoy", messages: history,
                        findings: [ExpectedFinding(kind: "appointment", title: "Quedar", start: start, end: start.addingTimeInterval(3600), allDay: false,
                                                   people: [], inferred: ["end"])])
        })

        s = SyntheticSetup(name: "chat-slack-x-needs-y", look: .slack, application: "Slack", platform: "macOS", clock24: false, palette: .light,
                           zone: mac, capturedAt: capture, windowTitle: "Slack - Acme Workspace", features: ["x-needs-y", "relative-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            chat(c, a, s, contact: "# project-atlas", separator: "Today", messages: chatHistory("Carlos needs to send the contract by Monday.", "Elena Mora", "9:41 AM"),
                 findings: [task("Send the contract", due: SyntheticTime.date(2026, 10, 19, zone: mac), people: ["Carlos"])])
        })

        s = SyntheticSetup(name: "chat-slack-reminder", look: .slack, application: "Slack", platform: "macOS", clock24: false, palette: .light,
                           zone: mac, capturedAt: capture, windowTitle: "Slack - Acme Workspace", features: ["relative-date"])
        out.append(try SyntheticChrome.make(s) { c, a in
            chat(c, a, s, contact: "# project-atlas", separator: "Today", messages: chatHistory("Remind me to call Ana at 5:00 PM today.", "Elena Mora", "9:44 AM"),
                 findings: [ExpectedFinding(kind: "reminder", title: "Call Ana", remind: SyntheticTime.date(2026, 10, 14, 17, 0, zone: mac), allDay: false, people: [])])
        })

        // Documents
        s = SyntheticSetup(name: "document-deadline-en", look: .plain, application: nil, platform: "macOS", clock24: nil, palette: .mac,
                           zone: mac, capturedAt: capture, windowTitle: "Grant proposal.docx", features: ["deadline"])
        out.append(try SyntheticChrome.make(s) { c, a in
            document(c, a, s, heading: "Grant proposal", paragraphs: [
                "This document describes the plan for the next funding round.", "The budget section still needs a final review.",
                "Submit the grant proposal by 2026-11-06.", "Contact the research office with any questions."],
                findings: [task("Submit the grant proposal", due: SyntheticTime.date(2026, 11, 6, zone: mac),
                                remind: SyntheticTime.date(2026, 11, 5, 9, 0, zone: mac), kind: "deadline")])
        })

        s = SyntheticSetup(name: "document-agenda-en", look: .plain, application: nil, platform: "macOS", palette: .mac, zone: mac,
                           capturedAt: capture, windowTitle: "Project agenda.docx", features: [])
        out.append(try SyntheticChrome.make(s) { c, a in
            document(c, a, s, heading: "Project agenda", paragraphs: [
                "Oct 20 - Kickoff 10:00-11:00", "Oct 22 - Design review 14:00-15:30", "Everyone should read the brief beforehand."],
                findings: [
                    ExpectedFinding(kind: "appointment", title: "Kickoff", start: SyntheticTime.date(2026, 10, 20, 10, 0, zone: mac),
                                    end: SyntheticTime.date(2026, 10, 20, 11, 0, zone: mac), allDay: false, people: []),
                    ExpectedFinding(kind: "appointment", title: "Design review", start: SyntheticTime.date(2026, 10, 22, 14, 0, zone: mac),
                                    end: SyntheticTime.date(2026, 10, 22, 15, 30, zone: mac), allDay: false, people: [])])
        })

        s = SyntheticSetup(name: "document-agenda-es", look: .plain, application: nil, platform: "macOS", language: .es, palette: .mac, zone: mac,
                           capturedAt: capture, windowTitle: "Orden del día.docx", features: [])
        out.append(try SyntheticChrome.make(s) { c, a in
            document(c, a, s, heading: "Orden del día", paragraphs: [
                "20 oct - Inicio del proyecto 10:00-11:00", "22 oct - Revisión de diseño 14:00-15:30", "Todos deben leer el resumen antes."],
                findings: [
                    ExpectedFinding(kind: "appointment", title: "Inicio del proyecto", start: SyntheticTime.date(2026, 10, 20, 10, 0, zone: mac),
                                    end: SyntheticTime.date(2026, 10, 20, 11, 0, zone: mac), allDay: false, people: []),
                    ExpectedFinding(kind: "appointment", title: "Revisión de diseño", start: SyntheticTime.date(2026, 10, 22, 14, 0, zone: mac),
                                    end: SyntheticTime.date(2026, 10, 22, 15, 30, zone: mac), allDay: false, people: [])])
        })

        // Other: nothing to find
        s = SyntheticSetup(name: "other-empty-window", look: .plain, application: nil, platform: "macOS", clock24: nil, palette: .mac, zone: mac,
                           capturedAt: capture, windowTitle: "Untitled", features: ["empty-picture"])
        out.append(try SyntheticChrome.make(s, chrome: false) { c, a in
            c.fill(a, RGB(0xC9D6E3))
            let window = CGRect(x: 260, y: 140, width: 1080, height: 720)
            c.fill(window, RGB(0xFFFFFF))
            c.stroke(window, RGB(0xA0A0A0))
            c.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 36), RGB(0xE6E6E6))
            return SyntheticDrawing(kind: .other, findings: [])
        })

        s = SyntheticSetup(name: "other-text-free-shapes", look: .plain, application: nil, platform: "macOS", clock24: nil, palette: .dark, zone: mac,
                           capturedAt: capture, windowTitle: "Charts", features: ["text-free-picture"])
        out.append(try SyntheticChrome.make(s, chrome: false) { c, a in
            for i in 0..<8 {
                let h = 120 + Double((i * 97) % 380)
                c.fill(CGRect(x: 200 + Double(i) * 130, y: 800 - h, width: 90, height: h), i % 2 == 0 ? RGB(0x4C8BF5) : RGB(0xF5A623))
            }
            c.fillCircle(center: CGPoint(x: 1380, y: 260), radius: 110, RGB(0x50C878))
            c.line(from: CGPoint(x: 160, y: 810), to: CGPoint(x: 1300, y: 810), RGB(0xA0A0A0), width: 2)
            return SyntheticDrawing(kind: .other, findings: [])
        })

        s = SyntheticSetup(name: "other-desktop-icons", look: .plain, application: nil, platform: "Windows", clock24: nil, palette: .light, zone: mac,
                           capturedAt: capture, windowTitle: "Desktop", features: [])
        out.append(try SyntheticChrome.make(s, chrome: false) { c, a in
            c.fill(a, RGB(0x2F6FA8))
            for (i, name) in ["Documents", "Downloads", "Trash", "Projects"].enumerated() {
                let x = 40.0, y = 40 + Double(i) * 130
                c.fillRounded(CGRect(x: x + 10, y: y, width: 56, height: 56), radius: 8, RGB(0xF2C94C))
                c.text(name, x: x, y: y + 66, size: 15, color: RGB(0xFFFFFF))
            }
            return SyntheticDrawing(kind: .other, findings: [])
        })
        return out
    }
}
