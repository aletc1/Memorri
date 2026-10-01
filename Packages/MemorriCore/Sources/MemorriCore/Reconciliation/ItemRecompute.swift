import Foundation
import GRDB
import os

/// What a sighting remembers about the finding behind it, beyond the observations: its kind and time zone, the rule that attached
/// it and the scores (FR-019). Stored as `sightings.decision_json`.
struct SightingDecision: Codable, Equatable {
    var rule: String
    var scores: MatchScores?
    var candidate: String?
    var kind: String
    var timezone: String

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func parse(_ text: String) -> SightingDecision? {
        try? JSONDecoder().decode(SightingDecision.self, from: Data(text.utf8))
    }
}

extension ItemStore {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "reconcile")

    /// Rebuilds an item's fields, aliases, kind, times and bookkeeping from its sightings and observations (research R9, data model
    /// "Rules"). An item left with no sightings is deleted unless the user touched, locked or dismissed it. Returns false when it was
    /// deleted or does not exist. Runs inside the caller's transaction.
    @discardableResult
    static func recompute(_ db: Database, itemID: String, at date: Date) throws -> Bool {
        guard var item = try Self.item(db, id: itemID) else { return false }
        if item.status == .merged {                     // kept as the record of a merge; nothing is built for it
            if item.needsReview { try db.execute(sql: "UPDATE items SET needs_review = 0, review_reasons_json = '[]' WHERE id = ?", arguments: [itemID]) }
            return true
        }
        let sightings = try Row.fetchAll(db, sql: "SELECT id, captured_at, confidence, decision_json FROM sightings WHERE item_id = ? ORDER BY captured_at, id",
                                         arguments: [itemID])
        let locks = try Row.fetchAll(db, sql: "SELECT field, observation_id FROM field_locks WHERE item_id = ?", arguments: [itemID])
        if sightings.isEmpty && !item.userTouched && locks.isEmpty && item.status != .dismissed {
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemID])
            return false
        }

        struct Seen { let id: String; let capturedAt: Date; let confidence: Double; let decision: SightingDecision? }
        let seen = sightings.map { Seen(id: $0["id"], capturedAt: $0["captured_at"], confidence: $0["confidence"],
                                        decision: SightingDecision.parse($0["decision_json"])) }
        let observations = try Self.observations(db, itemID: itemID)
        let lockMap = try Self.lockMap(db, itemID: itemID)
        let resolved = FieldResolver.resolve(observations, locks: lockMap)

        if !seen.isEmpty {
            // The most frequent kind among the sightings; a tie goes to the latest.
            var counts: [String: (count: Int, latest: Date)] = [:]
            for s in seen { if let kind = s.decision?.kind { let c = counts[kind]; counts[kind] = ((c?.count ?? 0) + 1, max(c?.latest ?? .distantPast, s.capturedAt)) } }
            if let best = counts.max(by: { ($0.value.count, $0.value.latest) < ($1.value.count, $1.value.latest) }), let kind = FindingKind(rawValue: best.key) {
                item.kind = kind
            }
            item.firstSeen = seen.map(\.capturedAt).min() ?? item.firstSeen
            item.lastSeen = seen.map(\.capturedAt).max() ?? item.lastSeen
            item.confidence = seen.map(\.confidence).max() ?? item.confidence
        }
        if let title = resolved.values[.title]?.asString { item.title = title }
        item.allDay = resolved.values[.allDay]?.asBool ?? false
        item.start = resolved.values[.start]?.asDate
        item.end = resolved.values[.end]?.asDate
        item.due = resolved.values[.due]?.asDate
        item.remind = resolved.values[.remind]?.asDate
        item.people = resolved.values[.people]?.asStrings ?? []
        item.place = resolved.values[.place]?.asString
        item.notes = resolved.values[.notes]?.asString

        // The zone of the sighting that gave the time, else of the latest sighting.
        let timeObservation = (item.family == .event ? resolved.chosen[.start] : (resolved.chosen[.due] ?? resolved.chosen[.start]))
        let timeSighting = timeObservation.flatMap { id in observations.first { $0.id == id }?.sightingID }
        if let zone = (seen.first { $0.id == timeSighting }?.decision?.timezone) ?? seen.last?.decision?.timezone { item.timezone = zone }
        item.dayKey = TimeAgreement.dayKey(item.family == .event ? item.start : (item.due ?? item.start), timezone: item.timezone)
        try Self.applyReview(db, to: &item, observations: observations, locks: lockMap, resolved: resolved)

        try update(db, item, at: date)
        try db.execute(sql: "DELETE FROM item_aliases WHERE item_id = ?", arguments: [itemID])
        var known: Set<String> = []
        for title in [item.title] + resolved.aliases {
            let form = TitleNormaliser.normalise(title)
            if form.isEmpty || !known.insert(form).inserted { continue }
            try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES (?, ?, ?)", arguments: [itemID, form, title])
        }
        return true
    }

    // MARK: Review state (spec 006)

    static func observations(_ db: Database, itemID: String) throws -> [ItemObservation] {
        try Row.fetchAll(db, sql: "SELECT * FROM observations WHERE item_id = ?", arguments: [itemID]).compactMap { row -> ItemObservation? in
            guard let field = ItemField(rawValue: row["field"]), let source = ObservationSource(rawValue: row["source"]),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data((row["value_json"] as String).utf8)) else { return nil }
            return ItemObservation(id: row["id"], itemID: itemID, sightingID: row["sighting_id"], field: field, value: value, source: source,
                                   confidence: row["confidence"], observedAt: row["observed_at"])
        }
    }

    /// Field to the observation behind its lock.
    static func lockMap(_ db: Database, itemID: String) throws -> [ItemField: String] {
        var map: [ItemField: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT field, observation_id FROM field_locks WHERE item_id = ?", arguments: [itemID]) {
            if let field = ItemField(rawValue: row["field"]) { map[field] = row["observation_id"] }
        }
        return map
    }

    /// Whether another item that is not merged away is an open possible duplicate of this one. A possible duplicate of a merged item
    /// is moot, which is why the merged partner is left out.
    static func hasOpenPossibleDuplicate(_ db: Database, itemID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM possible_duplicates p
                           JOIN items o ON o.id = CASE WHEN p.item_a = ?1 THEN p.item_b ELSE p.item_a END
                           WHERE (p.item_a = ?1 OR p.item_b = ?1) AND o.status != 'merged')
            """, arguments: [itemID]) ?? false
    }

    /// Sets `needsReview` and `reviewReasons` of an item whose fields are current. The approval snapshot is read from the row.
    static func applyReview(_ db: Database, to item: inout Item, observations: [ItemObservation], locks: [ItemField: String],
                            resolved: ResolvedFields) throws {
        var sources: [ItemField: ObservationSource] = [:]
        for (field, id) in resolved.chosen { if let observation = observations.first(where: { $0.id == id }) { sources[field] = observation.source } }
        var approved: [ItemField: JSONValue]?
        if item.approvedAt != nil {
            approved = ReviewRules.decode(try String.fetchOne(db, sql: "SELECT approved_values_json FROM items WHERE id = ?", arguments: [item.id]))
        }
        let reasons = ReviewRules.reasons(item: item, chosenSources: sources, locked: Set(locks.keys),
                                          hasOpenPossibleDuplicate: item.status == .active ? try hasOpenPossibleDuplicate(db, itemID: item.id) : false,
                                          approvedValues: approved, currentValues: ReviewRules.snapshot(of: item))
        item.reviewReasons = reasons
        item.needsReview = !reasons.isEmpty
    }

    /// Computes only the review columns of an item from what is stored (the one-off pass after the migration). Leaves everything else,
    /// including the time of the last change, alone.
    static func refreshReview(_ db: Database, itemID: String) throws {
        guard var item = try Self.item(db, id: itemID) else { return }
        let observations = try Self.observations(db, itemID: itemID)
        let locks = try lockMap(db, itemID: itemID)
        try applyReview(db, to: &item, observations: observations, locks: locks, resolved: FieldResolver.resolve(observations, locks: locks))
        let reasons = (try? JSONEncoder().encode(item.reviewReasons.map(\.rawValue))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        try db.execute(sql: "UPDATE items SET needs_review = ?, review_reasons_json = ? WHERE id = ?", arguments: [item.needsReview ? 1 : 0, reasons, itemID])
    }

    /// Recomputes other items whose review state depends on a change to this one (the partners of a possible duplicate).
    static func recomputeReview(_ db: Database, itemIDs: [String], at date: Date) throws {
        for id in Array(NSOrderedSet(array: itemIDs)) as? [String] ?? itemIDs {
            if let item = try item(db, id: id), item.status != .merged { try recompute(db, itemID: id, at: date) }
        }
    }

    /// The other items of every possible duplicate that names this one.
    static func possibleDuplicatePartners(_ db: Database, of itemID: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT CASE WHEN item_a = ?1 THEN item_b ELSE item_a END FROM possible_duplicates WHERE item_a = ?1 OR item_b = ?1 ORDER BY 1
            """, arguments: [itemID])
    }
}
