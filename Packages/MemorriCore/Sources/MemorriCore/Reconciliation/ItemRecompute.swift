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
        let observations = try Row.fetchAll(db, sql: "SELECT * FROM observations WHERE item_id = ?", arguments: [itemID]).compactMap { row -> ItemObservation? in
            guard let field = ItemField(rawValue: row["field"]), let source = ObservationSource(rawValue: row["source"]),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data((row["value_json"] as String).utf8)) else { return nil }
            return ItemObservation(id: row["id"], itemID: itemID, sightingID: row["sighting_id"], field: field, value: value, source: source,
                               confidence: row["confidence"], observedAt: row["observed_at"])
        }
        var lockMap: [ItemField: String] = [:]
        for row in locks { if let field = ItemField(rawValue: row["field"]) { lockMap[field] = row["observation_id"] } }
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
}
