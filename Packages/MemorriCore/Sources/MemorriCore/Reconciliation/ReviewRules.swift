import Foundation

/// When an item needs the user's eye (spec 006, research R5, FR-010). Pure: `ItemStore.recompute` gathers the inputs and stores
/// the answer on the item.
///
/// An item the user approved is judged only on what changed since: the approval covers the doubts that were there (low confidence,
/// guessed times, an undecided duplicate), so a later sighting of the same thing does not send it back to the Inbox (FR-012).
public enum ReviewRules {
    /// An item below this confidence needs review. Fixed, not a setting (clarification of 2026-10-01).
    public static let level = 0.75

    /// The fields an approval vouches for.
    public static let approvedFields: [ItemField] = [.title, .start, .end, .allDay, .due]

    /// The values of `approvedFields` as they are now (what an approval stores and what a later state is compared with).
    public static func snapshot(of item: Item) -> [ItemField: JSONValue] {
        [.title: .string(item.title), .start: .date(item.start), .end: .date(item.end), .allDay: .bool(item.allDay), .due: .date(item.due)]
    }

    /// How many different capture events must have covered an item without showing it (spec 010, clarification of 2026-10-02).
    public static let absencesForCancellation = 2

    /// Whether later captures of the same calendar dates left the item out often enough: absences from at least two different capture events, all
    /// taken after the item's latest sighting. After `Still happening` they count again only once the item was seen after that decision.
    public static func isPossiblyCancelled(absences: [CancelAbsence], lastSighting: Date?, clearedAt: Date?) -> Bool {
        guard let lastSighting else { return false }
        if let clearedAt, lastSighting <= clearedAt { return false }
        let later = absences.filter { $0.capturedAt > lastSighting }
        return Set(later.map(\.eventID)).count >= absencesForCancellation
    }

    public static func reasons(item: Item, chosenSources: [ItemField: ObservationSource], locked: Set<ItemField>, hasOpenPossibleDuplicate: Bool,
                               approvedValues: [ItemField: JSONValue]?, currentValues: [ItemField: JSONValue],
                               absences: [CancelAbsence] = [], lastSighting: Date? = nil, clearedAt: Date? = nil) -> [ReviewReason] {
        guard item.status == .active else { return [] }
        // A suspicion applies to every active item, approved or edited: it only asks the user to look.
        let cancelled = isPossiblyCancelled(absences: absences, lastSighting: lastSighting, clearedAt: clearedAt) ? [ReviewReason.possiblyCancelled] : []
        if let approvedValues {
            let changed = approvedFields.contains { (approvedValues[$0] ?? .null) != (currentValues[$0] ?? .null) }
            return (changed ? [.changedAfterApproval] : []) + cancelled
        }
        var reasons: [ReviewReason] = []
        if item.confidence < level { reasons.append(.lowConfidence) }
        func guessed(_ field: ItemField) -> Bool { chosenSources[field] == .inferred && !locked.contains(field) }
        if guessed(.start) { reasons.append(.guessedStart) }
        if guessed(.end) { reasons.append(.guessedEnd) }
        if guessed(.due) { reasons.append(.guessedDue) }
        if hasOpenPossibleDuplicate { reasons.append(.possibleDuplicate) }
        return reasons + cancelled
    }

    // MARK: Stored form of a snapshot

    static func encode(_ snapshot: [ItemField: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let named = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.rawValue, $0.value) })
        return (try? encoder.encode(named)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decode(_ text: String?) -> [ItemField: JSONValue]? {
        guard let text, let named = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) else { return nil }
        return Dictionary(named.compactMap { name, value in ItemField(rawValue: name).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }
}
