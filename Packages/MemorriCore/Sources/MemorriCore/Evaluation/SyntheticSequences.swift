import Foundation

/// The tracked sequence cases for `memorri-eval reconcile`: several sightings of invented events, with the answer (which event each
/// finding stands for) known by construction. Nothing is random and nothing reads the clock, so generating twice gives the same bytes.
public enum SyntheticSequences {
    /// 2026-10-14 07:00 UTC, a Wednesday.
    private static let wednesday = Date(timeIntervalSince1970: 1_791_961_200)
    private static let hour: TimeInterval = 3600, day: TimeInterval = 86400

    private static func at(day offset: Int, hour h: Double = 0) -> Date { wednesday.addingTimeInterval(Double(offset) * day + h * hour) }

    private static func timed(_ event: String, _ title: String, day d: Int = 0, hour h: Double = 0, length: Double? = 1, inferredEnd: Bool = false,
                              lang: String? = nil, confidence: Double = 0.9, kind: FindingKind = .appointment) -> SequenceCase.FindingSpec {
        SequenceCase.FindingSpec(event: event, kind: kind, title: title, lang: lang, start: at(day: d, hour: h), end: length.map { at(day: d, hour: h + $0) },
                                 inferred: inferredEnd ? ["end"] : [], confidence: confidence)
    }

    private static func todo(_ event: String, _ title: String, due: Date? = nil, kind: FindingKind = .task) -> SequenceCase.FindingSpec {
        SequenceCase.FindingSpec(event: event, kind: kind, title: title, due: due)
    }

    private static func capture(_ id: String, day d: Int, hour h: Double, context: String? = nil, _ findings: [SequenceCase.FindingSpec]) -> SequenceCase.CaptureSpec {
        SequenceCase.CaptureSpec(id: id, capturedAt: at(day: d - 3, hour: h - 7), context: context, findings: findings)
    }

    private static let utc = "UTC"
    private static let one = [SequenceCase.ContextSpec(id: "a", name: "Customer A", timezone: "Europe/Madrid")]
    private static let two = one + [SequenceCase.ContextSpec(id: "b", name: "Customer B", timezone: "America/New_York")]

    private static func sequence(_ name: String, contexts: [SequenceCase.ContextSpec] = one, captures: [SequenceCase.CaptureSpec],
                                 actions: [SequenceCase.Action] = []) -> SequenceCase {
        SequenceCase(name: name, macTimezone: utc, contexts: contexts, captures: captures, actions: actions)
    }

    public static let cases: [SequenceCase] = [
        sequence("truncated-titles", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [timed("planning", "Quarterly planning work", hour: 2, length: nil), timed("lunch", "Team lunch at the Corner Caf", hour: 5, length: nil)]),
            capture("c2", day: 0, hour: 9, context: "a", [timed("planning", "Quarterly planning workshop", hour: 2, length: 2), timed("lunch", "Team lunch", hour: 5, length: 1.5)]),
            capture("c3", day: 0, hour: 10, context: "a", [timed("planning", "Quarterly planning", hour: 2, length: nil, confidence: 0.6), timed("lunch", "Team lunch at the Corner Café", hour: 5, length: 1.5)]),
        ]),
        sequence("view-changes", captures: [
            capture("month", day: -2, hour: 8, context: "a", [timed("review", "Sprint review", hour: 4, length: nil), timed("retro", "Sprint retrospective", hour: 6, length: nil)]),
            capture("week", day: -1, hour: 8, context: "a", [timed("review", "Sprint review", hour: 4, length: 1, inferredEnd: true), timed("retro", "Sprint retrospective", hour: 6, length: 1, inferredEnd: true)]),
            capture("email", day: 0, hour: 8, context: "a", [timed("review", "Sprint review", hour: 4, length: 1.5), timed("retro", "Sprint retrospective", hour: 6, length: 1)]),
            capture("day", day: 0, hour: 12, context: "a", [timed("review", "Sprint review", hour: 4, length: 1.5, confidence: 0.95)]),
        ]),
        sequence("accents-and-case", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [timed("coffee", "Café con proveedores", hour: 3), timed("report", "Revisión mensual", hour: 6)]),
            capture("c2", day: 0, hour: 9, context: "a", [timed("coffee", "CAFE CON PROVEEDORES", hour: 3), timed("report", "Revision mensual.", hour: 6)]),
        ]),
        sequence("translated-titles", captures: [
            capture("en", day: 0, hour: 8, context: "a", [timed("standup", "Daily standup", hour: 1, length: 0.25, lang: "en"), timed("budget", "Budget review", hour: 4, lang: "en"),
                                                              timed("kickoff", "Project kickoff", hour: 7, lang: "en")]),
            capture("es", day: 0, hour: 9, context: "a", [timed("standup", "Reunión diaria", hour: 1, length: 0.25, lang: "es"), timed("budget", "Revisión de presupuesto", hour: 4, lang: "es"),
                                                              timed("kickoff", "Inicio del proyecto", hour: 7, lang: "es")]),
        ]),
        sequence("similar-different-meetings", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [timed("design", "Design review", hour: 4), timed("budget", "Budget review", hour: 4), timed("kickoff", "Project kickoff", hour: 6),
                                                          timed("sync", "Project sync", hour: 6)]),
            capture("c2", day: 0, hour: 9, context: "a", [timed("design", "Design review", hour: 4, length: 1.5), timed("budget", "Budget review", hour: 4, length: 1.5),
                                                          timed("kickoff", "Project kickoff", hour: 6, length: 1), timed("sync", "Project sync", hour: 6, length: 1)]),
        ]),
        sequence("recurring-standup", captures: (0..<5).flatMap { d in
            [capture("week\(d)a", day: d - 2, hour: 8, context: "a", [timed("standup-\(d)", "Daily standup", day: d - 2, hour: 1, length: 0.25, inferredEnd: true)]),
             capture("week\(d)b", day: d - 2, hour: 12, context: "a", [timed("standup-\(d)", "Daily standup", day: d - 2, hour: 1, length: 0.25)])]
        }),
        sequence("two-contexts", contexts: two, captures: [
            capture("a", day: 0, hour: 8, context: "a", [timed("a-sync", "Weekly sync", hour: 3)]),
            capture("b", day: 0, hour: 9, context: "b", [timed("b-sync", "Weekly sync", hour: 3)]),
            capture("a2", day: 0, hour: 10, context: "a", [timed("a-sync", "Weekly sync", hour: 3, length: 0.5)]),
            capture("b2", day: 0, hour: 11, context: "b", [timed("b-sync", "Weekly sync", hour: 3, length: 0.5)]),
        ]),
        sequence("all-day-and-timed", captures: [
            capture("month", day: -1, hour: 8, context: "a", [SequenceCase.FindingSpec(event: "offsite", kind: .appointment, title: "Company offsite", start: at(day: 0), allDay: true)]),
            capture("week", day: 0, hour: 8, context: "a", [timed("offsite", "Company offsite", hour: 2, length: 8)]),
        ]),
        sequence("undated-tasks", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [todo("permit", "Renew parking permit"), todo("passport", "Renew passport"), todo("invoice", "Send the monthly invoice"),
                                                          todo("report", "Send the monthly report")]),
            capture("c2", day: 0, hour: 9, context: "a", [todo("permit", "Renew parking permit"), todo("passport", "Renew passport"), todo("invoice", "Send the monthly invoice"),
                                                          todo("report", "Send the monthly report")]),
        ]),
        sequence("dismissed-stays-dismissed", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [timed("webinar", "Product webinar", hour: 5), timed("review", "Contract review", hour: 7)]),
            capture("c2", day: 0, hour: 9, context: "a", [timed("webinar", "Product webinar", hour: 5, length: 1), timed("review", "Contract review", hour: 7, length: 1)]),
            capture("c3", day: 0, hour: 10, context: "a", [timed("webinar", "Product webinar series", hour: 5, length: 1), timed("review", "Contract review", hour: 7, length: 1)]),
        ], actions: [SequenceCase.Action(after: "c1", action: .dismiss, event: "webinar")]),
        sequence("edited-title-stays", captures: [
            capture("c1", day: 0, hour: 8, context: "a", [timed("sync", "Weekly sync", hour: 2)]),
            capture("c2", day: 0, hour: 9, context: "a", [timed("sync", "Weekly sync", hour: 2, length: 1.5)]),
            capture("c3", day: 0, hour: 10, context: "a", [timed("sync", "Weekly sync meeting", hour: 2, length: 1.5, confidence: 0.95)]),
        ], actions: [SequenceCase.Action(after: "c1", action: .editTitle, event: "sync", title: "Sync with the platform team")]),
    ]

    /// Writes every case to `folder/<name>/sequence.json`. Returns the case folders.
    @discardableResult
    public static func generate(into folder: URL) throws -> [URL] {
        try cases.map { item in
            let target = folder.appendingPathComponent(item.name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try item.encoded().write(to: target.appendingPathComponent("sequence.json"))
            return target
        }
    }
}
