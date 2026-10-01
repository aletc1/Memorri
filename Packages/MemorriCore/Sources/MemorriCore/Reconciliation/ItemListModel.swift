import Foundation

public enum ItemKindFilter: String, Sendable, Equatable, CaseIterable {
    case all, appointments, tasks

    public var families: Set<KindFamily>? {
        switch self {
        case .all: nil
        case .appointments: [.event]
        case .tasks: [.todo]
        }
    }
}

public enum ItemContextFilter: Sendable, Hashable {
    case all
    /// Items that have no context.
    case none
    case context(String)

    /// The shape `ItemStore.items(contextID:)` takes.
    public var contextID: String?? {
        switch self {
        case .all: nil
        case .none: .some(nil)
        case .context(let id): .some(id)
        }
    }
}

/// What the Items window shows (contracts/ui-contract.md).
public struct ItemFilter: Sendable, Equatable {
    public var kind: ItemKindFilter
    public var context: ItemContextFilter
    public var showDismissed: Bool

    public init(kind: ItemKindFilter = .all, context: ItemContextFilter = .all, showDismissed: Bool = false) {
        self.kind = kind; self.context = context; self.showDismissed = showDismissed
    }

    public var statuses: Set<ItemStatus> { showDismissed ? [.active, .dismissed] : [.active] }
    public var families: Set<KindFamily>? { kind.families }
}

/// The words of one row.
public struct ItemRowText: Sendable, Equatable {
    public let title: String
    public let when: String
    public let context: String
    public let sightings: String
    public let possibleDuplicate: Bool
    public let locked: Bool
    public let dimmed: Bool
}

/// One of the values a merge cannot decide because the user locked both.
public struct LockChoice: Sendable, Equatable, Identifiable {
    public let field: ItemField
    public let keepItem: String
    public let keepValue: String
    public let otherItem: String
    public let otherValue: String
    public var id: String { field.rawValue }
    public var prompt: String { "Both items have your value for \(field.rawValue). Keep:" }
}

/// One card of an item's evidence: a sighting, its saved cut-out, or both. Evidence outlives its sighting (the capture may be gone).
public struct EvidenceEntry: Sendable, Equatable, Identifiable {
    public let sighting: SightingRow?
    public let evidence: EvidenceRecord?
    public var id: String { sighting?.id ?? evidence?.id ?? "" }
    public var capturedAt: Date { sighting?.capturedAt ?? evidence?.capturedAt ?? .distantPast }
    public var title: String { sighting?.title ?? evidence?.title ?? "" }
    public var displayName: String? { sighting?.displayName ?? evidence?.displayName }
}

/// The logic of the Items window, kept out of the views so it can be tested (spec 005, US5).
public enum ItemListModel {
    public enum StatusAction: Sendable, Equatable { case dismiss, restore }

    // MARK: List

    /// The rows the filter lets through, by start or due time, then title; undated last.
    public static func visible(_ rows: [ItemRow], filter: ItemFilter) -> [ItemRow] {
        rows.filter { row in
            guard filter.statuses.contains(row.item.status) else { return false }
            if let families = filter.families, !families.contains(row.item.family) { return false }
            switch filter.context {
            case .all: return true
            case .none: return row.item.contextID == nil
            case .context(let id): return row.item.contextID == id
            }
        }.sorted { a, b in
            switch (moment(a.item), moment(b.item)) {
            case let (x?, y?) where x != y: return x < y
            case (nil, .some): return false
            case (.some, nil): return true
            default:
                let order = a.item.title.localizedCaseInsensitiveCompare(b.item.title)
                return order != .orderedSame ? order == .orderedAscending : a.item.id < b.item.id
            }
        }
    }

    private static func moment(_ item: Item) -> Date? { item.family == .event ? item.start : (item.due ?? item.start) }

    public static func rowText(_ row: ItemRow, contextName: String?) -> ItemRowText {
        ItemRowText(title: row.item.title, when: dateText(row.item), context: contextName ?? "No context",
                    sightings: row.sightingCount == 1 ? "1 sighting" : "\(row.sightingCount) sightings",
                    possibleDuplicate: row.possibleDuplicate, locked: row.locked, dimmed: row.item.status == .dismissed)
    }

    /// The date and time in the item's own zone: `Wed 14 Oct 09:00`, `Wed 14 Oct, all day`, `Due Wed 14 Oct 09:00` or `No date`.
    public static func dateText(_ item: Item) -> String {
        guard let date = moment(item) else { return "No date" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: item.timezone) ?? TimeZone(identifier: "UTC")
        if item.allDay { formatter.dateFormat = "EEE d MMM"; return formatter.string(from: date) + ", all day" }
        formatter.dateFormat = "EEE d MMM HH:mm"
        let text = formatter.string(from: date)
        return item.family == .todo && item.due != nil ? "Due " + text : text
    }

    /// One field value as a person reads it.
    public static func valueText(_ value: JSONValue?, field: ItemField, timezone: String) -> String {
        guard let value else { return "none" }
        switch value {
        case .null: return "none"
        case .bool(let flag): return flag ? "yes" : "no"
        case .int(let n): return String(n)
        case .double(let x): return String(x)
        case .array(let values): return values.map { valueText($0, field: field, timezone: timezone) }.joined(separator: ", ")
        case .object: return "none"
        case .string(let text):
            guard let date = JSONValue.string(text).asDate else { return text }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")
            formatter.dateFormat = "EEE d MMM HH:mm"
            return formatter.string(from: date)
        }
    }

    // MARK: What the buttons can do

    public static func canMerge(_ rows: [ItemRow]) -> Bool { rows.count == 2 && rows.allSatisfy { $0.item.status != .merged } }

    /// `Dismiss` when every selected item is active, `Restore` when every one is dismissed, nothing for a mix or no selection.
    public static func statusAction(for rows: [ItemRow]) -> StatusAction? {
        guard !rows.isEmpty else { return nil }
        if rows.allSatisfy({ $0.item.status == .active }) { return .dismiss }
        if rows.allSatisfy({ $0.item.status == .dismissed }) { return .restore }
        return nil
    }

    /// A split needs a sighting to take out and at least one left behind.
    public static func canSplit(checked: Set<String>, of sightings: [SightingRow]) -> Bool {
        let ids = Set(sightings.map(\.id))
        let taken = checked.intersection(ids)
        return !taken.isEmpty && taken.count < ids.count
    }

    /// `Undo last`: the newest operation the user made that is not undone yet. An undo is not offered to be undone again, and an
    /// automatic merge is undone from an item's History. `operations` are newest first.
    public static func undoTarget(in operations: [OperationSummary]) -> OperationSummary? {
        operations.first { $0.byUser && !$0.undone && $0.kind != OperationKind.undo.rawValue }
    }

    /// The sheet of a merge that needs a choice: the two values of each field both items have locked.
    public static func lockChoices(for fields: [ItemField], keep: ItemDetail, other: ItemDetail) -> [LockChoice] {
        func text(_ detail: ItemDetail, _ field: ItemField) -> String {
            valueText(detail.fields.first { $0.field == field }?.current, field: field, timezone: detail.item.timezone)
        }
        return fields.map { LockChoice(field: $0, keepItem: keep.item.id, keepValue: text(keep, $0), otherItem: other.item.id, otherValue: text(other, $0)) }
    }

    // MARK: Words for the detail

    /// `read`, `guessed` or `you`.
    public static func sourceText(_ source: ObservationSource) -> String {
        switch source {
        case .read: "read"
        case .inferred: "guessed"
        case .user: "you"
        }
    }

    /// The field's current value and where it comes from.
    public static func fieldText(_ field: FieldHistory, timezone: String) -> (value: String, source: String?) {
        let chosen = field.entries.first { $0.observationID == field.chosenObservationID } ?? field.entries.first
        return (valueText(field.current, field: field.field, timezone: timezone), chosen.map { sourceText($0.source) })
    }

    /// Why a sighting joined its item or started a new one, from the stored decision: `text-time (text 1.00, time 1.00)`.
    public static func whyText(decisionJSON: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(decisionJSON.utf8))) as? [String: Any] else { return "" }
        let rule = (object["rule"] as? String) ?? "unknown"
        var parts: [String] = []
        if let scores = object["scores"] as? [String: Any] {
            for key in ["text", "time", "cosine", "rerank"] {
                if let value = scores[key] as? Double { parts.append(String(format: "%@ %.2f", key, value)) }
            }
        }
        return parts.isEmpty ? rule : "\(rule) (\(parts.joined(separator: ", ")))"
    }

    /// What an operation of the history was, in words.
    public static func operationText(_ kind: String) -> String {
        switch kind {
        case "auto_merge": "Merged automatically"
        case "merge": "Merged"
        case "split": "Split"
        case "dismiss": "Dismissed"
        case "restore": "Restored"
        case "edit": "Edited"
        case "unlock": "Unlocked"
        case "context": "Context changed"
        case "different": "Marked as different"
        case "undo": "Undone"
        default: kind
        }
    }

    // MARK: Evidence cards

    /// How many cards the detail shows before "Show all" (clarification 5).
    public static let evidenceCardsShown = 5

    /// Sightings and evidence joined, newest first: a card for every sighting (with its cut-out when it has one) and for every cut-out
    /// whose sighting is gone.
    public static func evidenceEntries(sightings: [SightingRow], evidence: [EvidenceRecord]) -> [EvidenceEntry] {
        let bySighting = Dictionary(evidence.compactMap { record in record.sightingID.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
        var entries = sightings.map { EvidenceEntry(sighting: $0, evidence: bySighting[$0.id]) }
        let known = Set(sightings.map(\.id))
        entries += evidence.filter { $0.sightingID.map(known.contains) != true }.map { EvidenceEntry(sighting: nil, evidence: $0) }
        return entries.sorted { $0.capturedAt != $1.capturedAt ? $0.capturedAt > $1.capturedAt : $0.id < $1.id }
    }

    /// The cards to show, and the text of the button that shows the rest (nil when everything is shown).
    public static func shownEntries(_ entries: [EvidenceEntry], showAll: Bool) -> (shown: [EvidenceEntry], moreText: String?) {
        guard !showAll, entries.count > evidenceCardsShown else { return (entries, nil) }
        return (Array(entries.prefix(evidenceCardsShown)), "Show all \(entries.count) sightings")
    }

    /// What a card says in place of a missing cut-out.
    public static func missingCutOutText(_ evidence: EvidenceRecord?) -> String {
        switch evidence?.reason {
        case "no-lines": "No cut-out: the finding cited no lines."
        case "picture-missing": "No cut-out: the capture was no longer stored when it was analysed."
        case "failed": "No cut-out: it could not be made."
        default: evidence == nil ? "No cut-out yet." : "The cut-out file is gone."
        }
    }
}
