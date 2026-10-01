import Foundation
import GRDB

extension Reconciler {
    // MARK: Reading what a plan needs

    static func snapshot(_ db: Database, imageID: String) throws -> Snapshot {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM image_analysis WHERE image_id = ?)", arguments: [imageID]) == true else {
            throw ReconcileError.noAnalysis
        }
        let findings = try AnalysisResultStore.findings(db, imageID: imageID)
        let context = try String?.fetchOne(db, sql: "SELECT context_id FROM image_context WHERE image_id = ?", arguments: [imageID]) ?? nil
        let contextName = try context.flatMap { try String.fetchOne(db, sql: "SELECT name FROM contexts WHERE id = ?", arguments: [$0]) }

        let earlier = try Row.fetchAll(db, sql: """
            SELECT s.id, s.item_id, s.title, (SELECT i.context_id FROM items i WHERE i.id = s.item_id) AS item_context,
                   (SELECT value_json FROM observations o WHERE o.sighting_id = s.id AND o.field = 'start') AS start_json,
                   (SELECT value_json FROM observations o WHERE o.sighting_id = s.id AND o.field = 'due') AS due_json
            FROM sightings s WHERE s.image_id = ? ORDER BY s.created_at, s.id
            """, arguments: [imageID]).map { row -> Earlier in
            func date(_ column: String) -> Date? {
                (row[column] as String?).flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }?.asDate
            }
            return Earlier(sightingID: row["id"], itemID: row["item_id"], itemContext: row["item_context"], title: row["title"],
                           when: date("start_json") ?? date("due_json"))
        }

        var keepApart: Set<[String]> = []
        for row in try Row.fetchAll(db, sql: "SELECT item_a, item_b FROM keep_apart") { keepApart.insert([row["item_a"], row["item_b"]]) }

        let candidates = try findings.map { try candidates(db, for: $0, context: context) }
        return Snapshot(findings: findings, context: context, contextName: contextName, earlier: earlier, candidates: candidates, keepApart: keepApart)
    }

    private static func candidates(_ db: Database, for finding: Finding, context: String?) throws -> [Candidate] {
        let span = Self.span(of: finding)
        var clause = "i.day_key IS NULL"
        var arguments: [any DatabaseValueConvertible] = [span.family.rawValue, context]
        if let start = span.start {
            var keys = [TimeAgreement.dayKey(start, timezone: span.timezone)]
            if span.family == .todo {
                keys = [-24, 0, 24].map { TimeAgreement.dayKey(start.addingTimeInterval(Double($0) * 3600), timezone: span.timezone) }
            }
            let unique = Array(Set(keys.compactMap { $0 })).sorted()
            clause = "i.day_key IN (\(unique.map { _ in "?" }.joined(separator: ", ")))"
            arguments += unique
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.*, (SELECT group_concat(a.normalised, char(31)) FROM item_aliases a WHERE a.item_id = i.id) AS aliases
            FROM items i
            WHERE i.status IN ('active', 'dismissed') AND i.family = ? AND i.context_id IS ? AND \(clause)
            """, arguments: StatementArguments(arguments))
        return rows.compactMap { row in
            guard let item = ItemStore.item(from: row) else { return nil }
            let aliases = (row["aliases"] as String?)?.split(separator: "\u{1F}").map(String.init) ?? []
            let titles = Array(Set(aliases + [TitleNormaliser.normalise(item.title)]))
            let itemSpan = TimeSpan(start: item.family == .event ? item.start : (item.due ?? item.start), end: item.family == .event ? item.end : nil,
                                    allDay: item.allDay, timezone: item.timezone, family: item.family)
            return Candidate(key: .item(item.id), itemID: item.id, title: item.title, titles: titles, spans: [itemSpan], lastSeen: item.lastSeen)
        }
    }

    // MARK: Apply

    /// Replaces the picture's earlier sightings with the plan's, creating, joining and recomputing items, in one transaction.
    public func apply(_ plan: ReconcilePlan) throws -> ReconcileSummary {
        let date = now()
        return try database.pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM image_analysis WHERE image_id = ?)", arguments: [plan.imageID]) == true else {
                throw ReconcileError.noAnalysis
            }
            let findings = Dictionary(try AnalysisResultStore.findings(db, imageID: plan.imageID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let context = try String?.fetchOne(db, sql: "SELECT context_id FROM image_context WHERE image_id = ?", arguments: [plan.imageID]) ?? nil
            let capturedAt = try Date.fetchOne(db, sql: """
                SELECT e.captured_at FROM capture_images i JOIN capture_events e ON e.id = i.event_id WHERE i.id = ?
                """, arguments: [plan.imageID]) ?? date

            // The earlier sightings go first; their items are recomputed at the end (and removed if nothing is left of them).
            var touched = Set(try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM sightings WHERE image_id = ?", arguments: [plan.imageID]))
            try db.execute(sql: "DELETE FROM sightings WHERE image_id = ?", arguments: [plan.imageID])

            var summary = ReconcileSummary()
            var resolved: [Int: String] = [:]
            var joins: [MovedSighting] = []
            for (index, step) in plan.steps.enumerated() {
                guard let finding = findings[step.findingID] else { continue }
                var itemID: String?
                var possibleOf: String?
                switch step.target {
                case .existing(let id): itemID = try Self.live(db, id)
                case .sameAsStep(let n): itemID = resolved[n]
                case .newItem: break
                case .newWithPossibleDuplicate(let other): possibleOf = try Self.live(db, other)
                }
                let joined = itemID != nil
                if itemID == nil {
                    let id = UUID().uuidString
                    try ItemStore.insert(db, Item(id: id, kind: finding.kind, contextID: context, title: finding.title, timezone: finding.timezone,
                                                  confidence: finding.confidence, firstSeen: capturedAt, lastSeen: capturedAt), at: date)
                    itemID = id
                    summary.created += 1
                    if let possibleOf {
                        let pair = [id, possibleOf].sorted()
                        let scores = step.scores.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        try db.execute(sql: "INSERT OR IGNORE INTO possible_duplicates (item_a, item_b, scores_json, created_at) VALUES (?, ?, ?, ?)",
                                       arguments: [pair[0], pair[1], scores, date])
                        summary.possibleDuplicates += 1
                    }
                } else {
                    summary.merged += 1
                }
                // A sighting that joins an item other pictures already showed is a merge the log can explain and undo; a finding that
                // goes back where this picture had it (a reanalysis) is not a new decision.
                var showedElsewhere = false
                if joined, step.rule != "same-picture" {
                    showedElsewhere = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sightings WHERE item_id = ? AND image_id != ?",
                                                        arguments: [itemID!, plan.imageID]) ?? 0) > 0
                }
                resolved[index] = itemID
                touched.insert(itemID!)
                let sighting = try Self.attach(db, finding: finding, itemID: itemID!, imageID: plan.imageID, capturedAt: capturedAt, step: step, at: date)
                if showedElsewhere { joins.append(MovedSighting(sighting: sighting, from: nil, to: itemID!)) }
            }
            if !joins.isEmpty {
                try OperationLog.record(db, kind: .autoMerge, byUser: false, items: joins.map(\.to), moved: joins,
                                        detail: ["image": .string(plan.imageID)], at: date)
            }

            for id in touched { try ItemStore.recompute(db, itemID: id, at: date) }
            try db.execute(sql: "UPDATE image_analysis SET reconciled_at = ?, reconcile_error = NULL WHERE image_id = ?", arguments: [date, plan.imageID])
            return summary
        }
    }

    /// The item to attach to: the one asked for, or the one it was merged into; nil when it is gone.
    private static func live(_ db: Database, _ id: String) throws -> String? {
        var current = id
        for _ in 0..<10 {
            guard let row = try Row.fetchOne(db, sql: "SELECT status, merged_into FROM items WHERE id = ?", arguments: [current]) else { return nil }
            if (row["status"] as String) == ItemStatus.merged.rawValue, let next = row["merged_into"] as String? { current = next } else { return current }
        }
        return nil
    }

    @discardableResult
    private static func attach(_ db: Database, finding: Finding, itemID: String, imageID: String, capturedAt: Date, step: ReconcilePlan.Step, at date: Date) throws -> String {
        let sightingID = UUID().uuidString
        let decision = SightingDecision(rule: step.rule, scores: step.scores, candidate: step.candidate, kind: finding.kind.rawValue, timezone: finding.timezone)
        let cited = (try? JSONEncoder().encode(finding.citedLines)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        try db.execute(sql: """
            INSERT INTO sightings (id, item_id, image_id, finding_id, captured_at, title, cited_lines_json, confidence, decision_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [sightingID, itemID, imageID, finding.id, capturedAt, finding.title, cited, finding.confidence, decision.json(), date])

        func source(_ key: String) -> ObservationSource { finding.provenance[key]?.origin == .inferred ? .inferred : .read }
        var values: [(ItemField, JSONValue, ObservationSource)] = [(.title, .string(finding.title), .read), (.allDay, .bool(finding.allDay), .read)]
        if let start = finding.start { values.append((.start, .date(start), source("start"))) }
        if let end = finding.end { values.append((.end, .date(end), source("end"))) }
        if let due = finding.due { values.append((.due, .date(due), source("due"))) }
        if let remind = finding.remind { values.append((.remind, .date(remind), source("remind"))) }
        if !finding.people.isEmpty { values.append((.people, .array(finding.people.map(JSONValue.string)), .read)) }
        if let place = finding.place, !place.isEmpty { values.append((.place, .string(place), .read)) }
        if let notes = finding.notes, !notes.isEmpty { values.append((.notes, .string(notes), .read)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (field, value, origin) in values {
            let json = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            try db.execute(sql: """
                INSERT INTO observations (id, item_id, sighting_id, field, value_json, source, confidence, observed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, itemID, sightingID, field.rawValue, json, origin.rawValue, min(max(finding.confidence, 0), 1), capturedAt])
        }
        return sightingID
    }
}
