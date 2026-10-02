import Foundation

public enum ItemKindFilter: String, Sendable, Equatable, CaseIterable {
    case all, appointments, tasks, reminders

    /// The to-do family covers tasks, deadlines and reminders; `kinds` tells them apart.
    public var families: Set<KindFamily>? {
        switch self {
        case .all: nil
        case .appointments: [.event]
        case .tasks, .reminders: [.todo]
        }
    }

    /// Tasks include deadlines (spec 006).
    public var kinds: Set<FindingKind>? {
        switch self {
        case .all: nil
        case .appointments: [.appointment]
        case .tasks: [.task, .deadline]
        case .reminders: [.reminder]
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

/// Which items the window lists by their review state (spec 006, FR-016): everything, the Inbox, or what is approved.
public enum ItemScope: String, Sendable, Equatable, CaseIterable { case all, inbox, approved }

/// What the Items window shows (contracts/ui-contract.md).
public struct ItemFilter: Sendable, Equatable {
    public var kind: ItemKindFilter
    public var context: ItemContextFilter
    public var showDismissed: Bool
    public var scope: ItemScope

    public init(kind: ItemKindFilter = .all, context: ItemContextFilter = .all, scope: ItemScope = .all, showDismissed: Bool = false) {
        self.kind = kind; self.context = context; self.scope = scope; self.showDismissed = showDismissed
    }

    public var statuses: Set<ItemStatus> { showDismissed ? [.active, .dismissed] : [.active] }
    public var families: Set<KindFamily>? { kind.families }
    public var kinds: Set<FindingKind>? { kind.kinds }
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
    /// `Needs review`, `Approved`, `Approved by you` or `Dismissed`.
    public let approval: String
    /// Why the item needs review, in words (empty when it does not).
    public let reasons: [String]
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
    /// The window the finding came from; the cut-out keeps it when the sighting is gone.
    public var windowApp: String? { sighting?.windowApp ?? evidence?.windowApp }
    public var windowTitle: String? { sighting?.windowTitle ?? evidence?.windowTitle }
}

/// Why an edit typed into a field was not accepted (spec 006, FR-007). The message goes under the field.
public enum EditError: Error, Equatable {
    case invalidDate, emptyTitle, invalidValue

    public var message: String {
        switch self {
        case .invalidDate: "Enter a date and time like 2026-10-14 09:00 (or a date like 2026-10-14)."
        case .emptyTitle: "The title cannot be empty."
        case .invalidValue: "That value is not valid."
        }
    }
}

/// One value that was seen or set for a field, for the list of values behind the current one (spec 006, FR-005).
public struct ProvenanceRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let value: String
    /// `read`, `guessed` or `you`.
    public let source: String
    /// The sighting's confidence as text; nil for a value the user set.
    public let confidence: String?
    /// When it was seen or set, in the item's zone.
    public let when: String
    public let isCurrent: Bool
    public let sightingID: String?
}

/// The logic of the Items window, kept out of the views so it can be tested (spec 005, US5).
public enum ItemListModel {
    public enum StatusAction: Sendable, Equatable { case dismiss, restore }

    // MARK: List

    /// The rows whose item is among `ids`, in the order of `ids` (best match first); `nil` means no search and keeps the rows as they are.
    public static func restrict(_ rows: [ItemRow], to ids: [String]?) -> [ItemRow] {
        guard let ids else { return rows }
        let byID = Dictionary(rows.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// The filter under which an item with this status is in the list: every kind, every context, the whole scope, and dismissed items only when it is one.
    public static func filter(showing status: ItemStatus) -> ItemFilter {
        ItemFilter(kind: .all, context: .all, scope: .all, showDismissed: status == .dismissed)
    }

    /// The rows the filter lets through, by start or due time, then title; undated last.
    public static func visible(_ rows: [ItemRow], filter: ItemFilter) -> [ItemRow] {
        rows.filter { row in
            guard filter.statuses.contains(row.item.status) else { return false }
            switch filter.scope {
            case .all: break
            case .inbox: guard row.item.status == .active, row.item.needsReview else { return false }
            case .approved: guard row.item.status == .active, !row.item.needsReview else { return false }
            }
            if let kinds = filter.kinds, !kinds.contains(row.item.kind) { return false }
            switch filter.context {
            case .all: return true
            case .none: return row.item.contextID == nil
            case .context(let id): return row.item.contextID == id
            }
        }.sorted { a, b in
            // The Inbox shows what was seen last first; the other lists go by date.
            if filter.scope == .inbox, a.item.lastSeen != b.item.lastSeen { return a.item.lastSeen > b.item.lastSeen }
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

    /// The date an item is listed and pinned by: an event's start, a to-do's due date, else its start.
    public static func moment(_ item: Item) -> Date? { item.family == .event ? item.start : (item.due ?? item.start) }

    public static func rowText(_ row: ItemRow, contextName: String?) -> ItemRowText {
        ItemRowText(title: row.item.title, when: dateText(row.item), context: contextName ?? "No context",
                    sightings: row.sightingCount == 1 ? "1 sighting" : "\(row.sightingCount) sightings",
                    possibleDuplicate: row.possibleDuplicate, locked: row.locked, dimmed: row.item.status == .dismissed,
                    approval: approvalText(row.item), reasons: reviewText(row.item.reviewReasons))
    }

    // MARK: Review (spec 006)

    /// How many items the Inbox lists with the filter's kind and context (the number in the scope label, FR-017).
    public static func inboxCount(_ rows: [ItemRow], filter: ItemFilter) -> Int {
        visible(rows, filter: ItemFilter(kind: filter.kind, context: filter.context, scope: .inbox)).count
    }

    /// One reason an item needs review, in words.
    public static func reviewText(_ reasons: [ReviewReason]) -> [String] {
        reasons.map { reason in
            switch reason {
            case .lowConfidence: "Low confidence"
            case .guessedStart: "Guessed time"
            case .guessedEnd: "Guessed end"
            case .guessedDue: "Guessed due date"
            case .possibleDuplicate: "Possible duplicate"
            case .changedAfterApproval: "Changed after you approved it"
            case .possiblyCancelled: "Possibly cancelled"
            }
        }
    }

    /// The line of the item detail for a possibly cancelled item: how many captures of the calendar left it out since it was last seen.
    public static func suspicionText(_ suspicion: CancelSuspicion) -> String {
        let count = suspicion.notShownIn.count
        return "It was not in the last \(count) \(count == 1 ? "capture" : "captures") of this calendar that covered its time."
    }

    /// An item that does not need review counts as approved without any action (FR-013).
    public static func approvalText(_ item: Item) -> String {
        if item.status == .dismissed { return "Dismissed" }
        if item.needsReview { return "Needs review" }
        return item.approvedAt != nil ? "Approved by you" : "Approved"
    }

    /// `Approve` is offered when every selected item is waiting for review.
    public static func canApprove(_ rows: [ItemRow]) -> Bool { !rows.isEmpty && rows.allSatisfy { $0.item.needsReview } }

    /// What the list says when the scope has nothing to show.
    public static func emptyText(scope: ItemScope) -> String {
        switch scope {
        case .all: "No items yet. Items appear after captures are analysed."
        case .inbox: "Nothing needs review."
        case .approved: "No approved items yet."
        }
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

    /// Every value seen or set for a field, newest first, with the one that is current marked (FR-005).
    public static func provenance(_ field: FieldHistory, timezone: String) -> [ProvenanceRow] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE d MMM HH:mm"
        return field.entries.map { entry in
            ProvenanceRow(id: entry.observationID, value: valueText(entry.value, field: field.field, timezone: timezone), source: sourceText(entry.source),
                          confidence: entry.sightingID == nil ? nil : String(format: "%.2f", entry.confidence), when: formatter.string(from: entry.observedAt),
                          isCurrent: entry.observationID == field.chosenObservationID, sightingID: entry.sightingID)
        }
    }

    /// The sighting the current value of a field came from; nil for a value the user set or a field with no value.
    public static func sourceSightingID(_ field: FieldHistory?) -> String? {
        guard let field, let chosen = field.chosenObservationID else { return nil }
        return field.entries.first { $0.observationID == chosen }?.sightingID
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
    /// A line of the item's history: the operation, the field an edit changed, and where a change was made when it was not in Memorri.
    public static func historyText(kind: String, detail: [String: JSONValue]) -> String {
        var text = operationText(kind)
        if kind == "edit", let field = detail["field"]?.asString { text += " \(field)" }
        if let source = detail["source"]?.asString { text += " (in \(source))" }
        return text
    }

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
        case "approve": "Approved"
        case "still_happening": "Marked as still happening"
        case "undo": "Undone"
        case "apply_trial": "Applied a reprocessing trial"
        default: kind
        }
    }

    // MARK: Editing (spec 006)

    private static func editFormatter(_ format: String, timezone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }

    /// Turns what the user typed into the value `ItemOperations.edit` takes. Dates are read in the item's own zone; an empty text clears an
    /// optional field.
    public static func parse(_ text: String, field: ItemField, timezone: String) -> Result<JSONValue, EditError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .title: return trimmed.isEmpty ? .failure(.emptyTitle) : .success(.string(trimmed))
        case .place, .notes: return .success(trimmed.isEmpty ? .null : .string(trimmed))
        case .people:
            var seen: Set<String> = []
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { name in
                !name.isEmpty && seen.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
            }
            return .success(.array(names.map(JSONValue.string)))
        case .allDay:
            switch trimmed.lowercased() {
            case "yes", "true", "1": return .success(.bool(true))
            case "no", "false", "0": return .success(.bool(false))
            default: return .failure(.invalidValue)
            }
        case .start, .end, .due, .remind:
            if trimmed.isEmpty { return field == .start ? .failure(.invalidDate) : .success(.null) }
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                if let date = editFormatter(format, timezone: timezone).date(from: trimmed) { return .success(.date(date)) }
            }
            return .failure(.invalidDate)
        }
    }

    /// The text an editor starts with: what `parse` reads back (`2026-10-14 09:00` in the item's zone, names joined by commas).
    public static func editText(_ value: JSONValue?, field: ItemField, timezone: String) -> String {
        guard let value, value != .null else { return "" }
        switch field {
        case .start, .end, .due, .remind:
            return value.asDate.map { editFormatter("yyyy-MM-dd HH:mm", timezone: timezone).string(from: $0) } ?? ""
        case .people: return (value.asStrings ?? []).joined(separator: ", ")
        case .allDay: return value.asBool == true ? "yes" : "no"
        case .title, .place, .notes: return value.asString ?? ""
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

    /// Which window a card's evidence came from: `"<app> — <title>"`, `"<app>"` when the window had no title, nil when there is no window
    /// (a capture read as a whole, or from before windows were read).
    public static func windowText(_ entry: EvidenceEntry) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        switch (clean(entry.windowApp), clean(entry.windowTitle)) {
        case let (app?, title?): return "\(app) — \(title)"
        case let (app?, nil): return app
        case let (nil, title?): return title
        case (nil, nil): return nil
        }
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
