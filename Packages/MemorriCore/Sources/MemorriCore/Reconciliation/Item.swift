import Foundation

/// Appointments are events; tasks, reminders and deadlines are things to do. Candidates are matched within a family.
public enum KindFamily: String, Sendable, Equatable {
    case event, todo

    public init(kind: FindingKind) { self = kind == .appointment ? .event : .todo }
}

public enum ItemStatus: String, Sendable, Equatable { case active, dismissed, merged }

public enum ItemField: String, Sendable, Equatable, CaseIterable {
    case title, start, end, allDay = "all_day", due, remind, people, place, notes
}

public enum ObservationSource: String, Sendable, Equatable { case read, inferred, user }

/// Why an item needs review (spec 006, research R5). The order is the order they are shown in.
public enum ReviewReason: String, Sendable, Equatable, Codable, CaseIterable {
    case lowConfidence = "low-confidence"
    case guessedStart = "guessed-start"
    case guessedEnd = "guessed-end"
    case guessedDue = "guessed-due"
    case possibleDuplicate = "possible-duplicate"
    case changedAfterApproval = "changed-after-approval"
}

/// One real-world appointment, task or reminder, made of one or more sightings. Its fields are chosen from observations
/// by `FieldResolver` (ADR 0020).
public struct Item: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: FindingKind
    public var status: ItemStatus
    public var mergedInto: String?
    public var contextID: String?
    public var title: String
    public var allDay: Bool
    public var start: Date?
    public var end: Date?
    public var due: Date?
    public var remind: Date?
    public var timezone: String
    /// `YYYY-MM-DD` of the start (event) or due date (to-do) in `timezone`; nil when undated. The candidate index.
    public var dayKey: String?
    public var people: [String]
    public var place: String?
    public var notes: String?
    public var confidence: Double
    public var userTouched: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    /// Stored by every recompute (`ReviewRules`); what the Inbox lists.
    public var needsReview: Bool
    public var reviewReasons: [ReviewReason]
    /// When the user approved the item or edited it; nil while nobody checked it.
    public var approvedAt: Date?

    public var family: KindFamily { KindFamily(kind: kind) }

    public init(id: String = UUID().uuidString, kind: FindingKind, status: ItemStatus = .active, mergedInto: String? = nil, contextID: String? = nil,
                title: String, allDay: Bool = false, start: Date? = nil, end: Date? = nil, due: Date? = nil, remind: Date? = nil,
                timezone: String, dayKey: String? = nil, people: [String] = [], place: String? = nil, notes: String? = nil,
                confidence: Double, userTouched: Bool = false, firstSeen: Date, lastSeen: Date,
                needsReview: Bool = false, reviewReasons: [ReviewReason] = [], approvedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.status = status; self.mergedInto = mergedInto; self.contextID = contextID
        self.title = title; self.allDay = allDay; self.start = start; self.end = end; self.due = due; self.remind = remind
        self.timezone = timezone; self.dayKey = dayKey; self.people = people; self.place = place; self.notes = notes
        self.confidence = confidence; self.userTouched = userTouched; self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.needsReview = needsReview; self.reviewReasons = reviewReasons; self.approvedAt = approvedAt
    }
}

/// One sighting of one field of an item: the value as found, with where it came from.
public struct ItemObservation: Sendable, Equatable {
    public let id: String
    public let itemID: String
    /// Nil for a value the user set.
    public let sightingID: String?
    public let field: ItemField
    public let value: JSONValue
    public let source: ObservationSource
    public let confidence: Double
    public let observedAt: Date

    public init(id: String = UUID().uuidString, itemID: String, sightingID: String?, field: ItemField, value: JSONValue,
                source: ObservationSource, confidence: Double, observedAt: Date) {
        self.id = id; self.itemID = itemID; self.sightingID = sightingID; self.field = field; self.value = value
        self.source = source; self.confidence = confidence; self.observedAt = observedAt
    }
}

extension JSONValue {
    private static let isoFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// A date as a UTC ISO 8601 string, or `null`.
    public static func date(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(isoFormat)) } ?? .null
    }

    public var asDate: Date? {
        guard case .string(let text) = self else { return nil }
        return try? Date(text, strategy: Self.isoFormat)
    }

    public var asString: String? { if case .string(let text) = self { text } else { nil } }
    public var asBool: Bool? { if case .bool(let flag) = self { flag } else { nil } }
    public var asStrings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.asString)
    }
}
