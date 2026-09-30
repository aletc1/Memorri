import Foundation

public enum FindingKind: String, Sendable, Codable, CaseIterable { case appointment, task, reminder, deadline }

public enum FieldOrigin: String, Sendable, Codable { case read, inferred }

/// Where a date or time value came from: read on screen, or inferred by a named rule.
public struct FieldProvenance: Sendable, Codable, Equatable {
    public let origin: FieldOrigin
    public let rule: String
    public let reason: String?

    public init(origin: FieldOrigin, rule: String, reason: String? = nil) {
        self.origin = origin; self.rule = rule; self.reason = reason
    }
}

/// One environment fact about a picture (application, platform look, clock style, ...), kept with where it came from.
public struct CaptureTag: Sendable, Equatable, Codable {
    public let key: String
    public let value: String
    public let confidence: Double
    public let source: String

    public init(key: String, value: String, confidence: Double, source: String) {
        self.key = key; self.value = value; self.confidence = confidence; self.source = source
    }
}

/// What the model said about one finding: literal texts and the numbers of the lines they come from.
public struct FindingDraft: Sendable, Equatable {
    public let kind: FindingKind
    public let title: String
    public let citedLines: [Int]
    public let startText: String?
    public let endText: String?
    public let dateText: String?
    public let dueText: String?
    public let remindText: String?
    public let allDay: Bool?
    public let people: [String]
    public let place: String?
    public let notes: String?
    public let columnLine: Int?
    public let sentText: String?
    public let messageTimeText: String?

    public init(kind: FindingKind, title: String, citedLines: [Int], startText: String? = nil, endText: String? = nil,
                dateText: String? = nil, dueText: String? = nil, remindText: String? = nil, allDay: Bool? = nil,
                people: [String] = [], place: String? = nil, notes: String? = nil, columnLine: Int? = nil,
                sentText: String? = nil, messageTimeText: String? = nil) {
        self.kind = kind; self.title = title; self.citedLines = citedLines; self.startText = startText; self.endText = endText
        self.dateText = dateText; self.dueText = dueText; self.remindText = remindText; self.allDay = allDay; self.people = people
        self.place = place; self.notes = notes; self.columnLine = columnLine; self.sentText = sentText
        self.messageTimeText = messageTimeText
    }

    /// Reads one item of an answer's `findings` list; nil for an unknown kind, an empty title or a missing `cited_lines`.
    public static func parse(_ value: JSONValue) -> FindingDraft? {
        guard let kind = value["kind"]?.stringValue.flatMap(FindingKind.init(rawValue:)),
              let title = value["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let cited = value["cited_lines"]?.arrayValue else { return nil }
        let numbers = cited.compactMap { item -> Int? in if case .int(let n) = item { n } else { nil } }
        guard numbers.count == cited.count else { return nil }
        func text(_ key: String) -> String? {
            guard let raw = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        let people = (value["people"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var column: Int?
        if case .int(let n)? = value["column_line"] { column = n }
        return FindingDraft(kind: kind, title: title, citedLines: numbers, startText: text("start_text"), endText: text("end_text"),
                            dateText: text("date_text"), dueText: text("due_text"), remindText: text("remind_text"),
                            allDay: value["all_day"]?.boolValue, people: people, place: text("place"), notes: text("notes"),
                            columnLine: column, sentText: text("sent_text"), messageTimeText: text("message_time_text"))
    }

    func withCitedLines(_ lines: [Int]) -> FindingDraft {
        FindingDraft(kind: kind, title: title, citedLines: lines, startText: startText, endText: endText, dateText: dateText,
                     dueText: dueText, remindText: remindText, allDay: allDay, people: people, place: place, notes: notes,
                     columnLine: columnLine, sentText: sentText, messageTimeText: messageTimeText)
    }
}

/// A finding that was checked and resolved. Dates the resolver could not settle stay `nil` with their text in `unresolved`.
public struct Finding: Sendable, Equatable {
    /// The fields that carry provenance: date and time values. Title, people, place and notes are always read, by citation.
    public static let provenanceFields = ["start", "end", "due", "remind", "allDay"]

    public let id: String
    public let kind: FindingKind
    public let title: String
    public let allDay: Bool
    public let start: Date?
    public let end: Date?
    public let due: Date?
    public let remind: Date?
    public let timezone: String
    public let people: [String]
    public let place: String?
    public let notes: String?
    public let citedLines: [Int]
    public let confidence: Double
    public let provenance: [String: FieldProvenance]
    public let unresolved: [String: String]
    /// A copy of the picture's tags at the time of this run.
    public let tags: [CaptureTag]

    public init(id: String = UUID().uuidString, kind: FindingKind, title: String, allDay: Bool, start: Date? = nil, end: Date? = nil,
                due: Date? = nil, remind: Date? = nil, timezone: String, people: [String] = [], place: String? = nil,
                notes: String? = nil, citedLines: [Int], confidence: Double, provenance: [String: FieldProvenance] = [:],
                unresolved: [String: String] = [:], tags: [CaptureTag] = []) {
        self.id = id; self.kind = kind; self.title = title; self.allDay = allDay; self.start = start; self.end = end
        self.due = due; self.remind = remind; self.timezone = timezone; self.people = people; self.place = place
        self.notes = notes; self.citedLines = citedLines; self.confidence = confidence
        self.provenance = provenance.filter { Self.provenanceFields.contains($0.key) }
        self.unresolved = unresolved; self.tags = tags
    }

    /// The lowest confidence among the cited lines (0 when none of them exists), at most 0.5 when any field is inferred.
    public static func confidence(citing cited: [Int], in lines: [RecognisedLine], anyInferred: Bool) -> Double {
        let values = cited.compactMap { n in lines.first { $0.n == n }?.confidence }
        guard let lowest = values.min() else { return 0 }
        return anyInferred ? min(lowest, 0.5) : lowest
    }
}

public enum CitationCheck {
    public struct Discard: Sendable, Equatable, Codable {
        public let title: String
        public let reason: String
        public let citedLines: [Int]
        enum CodingKeys: String, CodingKey { case title, reason, citedLines = "cited_lines" }
    }

    /// Keeps drafts that cite at least one line and only existing lines (numbers 1 to `lineCount`); the others become
    /// discards. Cited numbers of the kept drafts are sorted and distinct.
    public static func apply(_ drafts: [FindingDraft], lineCount: Int) -> (kept: [FindingDraft], discarded: [Discard]) {
        var kept: [FindingDraft] = [], discarded: [Discard] = []
        for draft in drafts {
            if draft.citedLines.isEmpty {
                discarded.append(Discard(title: draft.title, reason: "cites no line", citedLines: []))
            } else if draft.citedLines.contains(where: { $0 < 1 || $0 > lineCount }) {
                discarded.append(Discard(title: draft.title, reason: "cites a line that does not exist", citedLines: draft.citedLines))
            } else {
                kept.append(draft.withCitedLines(Array(Set(draft.citedLines)).sorted()))
            }
        }
        return (kept, discarded)
    }
}
