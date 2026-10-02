import Foundation
import GRDB

public enum ItemStoreError: Error, Equatable { case notFound }

/// An item as the list shows it.
public struct ItemRow: Sendable, Equatable {
    public let item: Item
    public let sightingCount: Int
    public let locked: Bool
    public let possibleDuplicate: Bool
}

/// One operation on an item as its history shows it.
public struct OperationSummary: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let byUser: Bool
    public let createdAt: Date
    public let undone: Bool
    /// What the operation recorded about itself (the field an edit changed, where the change was made).
    public var detail: [String: JSONValue] = [:]

    static func decodeDetail(_ json: String?) -> [String: JSONValue] {
        json.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) } ?? [:]
    }
}

/// Everything known about one item (research R9, contracts/core-interfaces.md).
public struct ItemDetail: Sendable, Equatable {
    public let item: Item
    public var fields: [FieldHistory] = []
    public var sightings: [SightingRow] = []
    public var aliases: [String] = []
    /// The observation behind each locked field.
    public var locks: [ItemField: String] = [:]
    /// The other item of each open possible duplicate.
    public var possibleDuplicates: [String] = []
    public var operations: [OperationSummary] = []
}

/// One field with its current value and every observation behind it.
public struct FieldHistory: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let observationID: String
        public let value: JSONValue
        public let source: ObservationSource
        public let confidence: Double
        public let observedAt: Date
        public let sightingID: String?
        public let imageID: String?
        public let citedLines: [Int]
    }
    public let field: ItemField
    public let current: JSONValue?
    public let chosenObservationID: String?
    public let locked: Bool
    public let entries: [Entry]
}

/// One sighting of an item.
public struct SightingRow: Sendable, Equatable {
    public let id: String
    public let imageID: String
    public let displayName: String?
    public let capturedAt: Date
    public let title: String
    public let confidence: Double
    public let citedLines: [Int]
    /// The stored decision (rule and scores) as JSON text.
    public let decisionJSON: String
    /// The window the finding came from (application and title), when the capture was read by window.
    public var windowApp: String? = nil
    public var windowTitle: String? = nil
}

/// Reads and writes the item tables. The reconciler and the operations use the static helpers inside their own transactions.
public struct ItemStore: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    // MARK: Reading

    /// `contextID`: nil for any context, `.some(nil)` for items without one, `.some(id)` for one context.
    /// `review`: only the items that need review (the Inbox).
    public func items(status: Set<ItemStatus>, kinds: Set<KindFamily>?, contextID: String??, review: Bool = false) throws -> [ItemRow] {
        try database.pool.read { try Self.rows($0, status: status, kinds: kinds, contextID: contextID, review: review) }
    }

    /// How many items need review: what the Inbox lists (FR-017). `contextID` as in `items`.
    public func reviewCount(contextID: String?? = nil) throws -> Int {
        try database.pool.read { try Self.reviewCount($0, contextID: contextID) }
    }

    static func reviewCount(_ db: Database, contextID: String??) throws -> Int {
        var sql = "SELECT COUNT(*) FROM items WHERE status = 'active' AND needs_review = 1"
        var arguments: [any DatabaseValueConvertible] = []
        if let contextID {
            if let id = contextID { sql += " AND context_id = ?"; arguments.append(id) } else { sql += " AND context_id IS NULL" }
        }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
    }

    /// The count of items needing review, again after every change to the items.
    public func observeReviewCount(contextID: String?? = nil) -> AsyncStream<Int> {
        let observation = ValueObservation.tracking { db in try Self.reviewCount(db, contextID: contextID) }
        let pool = database.pool
        return AsyncStream { continuation in
            let task = Task {
                do { for try await count in observation.values(in: pool) { continuation.yield(count) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(id: String) throws -> Item? {
        try database.pool.read { try Self.item($0, id: id) }
    }

    public func detail(itemID: String) throws -> ItemDetail {
        try database.pool.read { db in
            guard let item = try Self.item(db, id: itemID) else { throw ItemStoreError.notFound }
            return try Self.detail(db, item: item)
        }
    }

    static func detail(_ db: Database, item: Item) throws -> ItemDetail {
        var detail = ItemDetail(item: item)
        let decoder = JSONDecoder()

        var locks: [ItemField: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT field, observation_id FROM field_locks WHERE item_id = ?", arguments: [item.id]) {
            if let field = ItemField(rawValue: row["field"]) { locks[field] = row["observation_id"] }
        }
        detail.locks = locks

        struct Source { let observation: ItemObservation; let imageID: String?; let cited: [Int] }
        let sources: [Source] = try Row.fetchAll(db, sql: """
            SELECT o.*, s.image_id AS image_id, s.cited_lines_json AS cited
            FROM observations o LEFT JOIN sightings s ON s.id = o.sighting_id
            WHERE o.item_id = ? ORDER BY o.observed_at DESC, o.id
            """, arguments: [item.id]).compactMap { row in
            guard let field = ItemField(rawValue: row["field"]), let source = ObservationSource(rawValue: row["source"]),
                  let value = try? decoder.decode(JSONValue.self, from: Data((row["value_json"] as String).utf8)) else { return nil }
            let cited = (row["cited"] as String?).flatMap { try? decoder.decode([Int].self, from: Data($0.utf8)) } ?? []
            return Source(observation: ItemObservation(id: row["id"], itemID: item.id, sightingID: row["sighting_id"], field: field, value: value,
                                                      source: source, confidence: row["confidence"], observedAt: row["observed_at"]),
                          imageID: row["image_id"], cited: cited)
        }
        let resolved = FieldResolver.resolve(sources.map(\.observation), locks: locks)
        detail.fields = ItemField.allCases.compactMap { field in
            let own = sources.filter { $0.observation.field == field }
            guard !own.isEmpty else { return nil }
            return FieldHistory(field: field, current: resolved.values[field], chosenObservationID: resolved.chosen[field], locked: locks[field] != nil,
                                entries: own.map { FieldHistory.Entry(observationID: $0.observation.id, value: $0.observation.value, source: $0.observation.source,
                                                                      confidence: $0.observation.confidence, observedAt: $0.observation.observedAt,
                                                                      sightingID: $0.observation.sightingID, imageID: $0.imageID, citedLines: $0.cited) })
        }

        detail.sightings = try Row.fetchAll(db, sql: """
            SELECT s.*, i.display_name AS display_name FROM sightings s JOIN capture_images i ON i.id = s.image_id
            WHERE s.item_id = ? ORDER BY s.captured_at DESC, s.id
            """, arguments: [item.id]).map { row in
            SightingRow(id: row["id"], imageID: row["image_id"], displayName: row["display_name"], capturedAt: row["captured_at"], title: row["title"],
                        confidence: row["confidence"], citedLines: (try? decoder.decode([Int].self, from: Data((row["cited_lines_json"] as String).utf8))) ?? [],
                        decisionJSON: row["decision_json"], windowApp: row["window_app"], windowTitle: row["window_title"])
        }

        let own = TitleNormaliser.normalise(item.title)
        detail.aliases = try Row.fetchAll(db, sql: "SELECT normalised, title FROM item_aliases WHERE item_id = ? ORDER BY normalised", arguments: [item.id])
            .filter { ($0["normalised"] as String) != own }.map { $0["title"] as String }

        detail.possibleDuplicates = try Row.fetchAll(db, sql: """
            SELECT p.item_a, p.item_b FROM possible_duplicates p
            JOIN items o ON o.id = CASE WHEN p.item_a = ?1 THEN p.item_b ELSE p.item_a END
            WHERE (p.item_a = ?1 OR p.item_b = ?1) AND o.status != 'merged' ORDER BY p.item_a, p.item_b
            """, arguments: [item.id]).map { ($0["item_a"] as String) == item.id ? $0["item_b"] : $0["item_a"] }

        detail.operations = try Row.fetchAll(db, sql: """
            SELECT o.id, o.kind, o.by_user, o.created_at, o.undone_by, o.detail_json FROM reconcile_ops o JOIN reconcile_op_items oi ON oi.op_id = o.id
            WHERE oi.item_id = ? ORDER BY o.created_at DESC, o.rowid DESC
            """, arguments: [item.id]).map { row in
            OperationSummary(id: row["id"], kind: row["kind"], byUser: (row["by_user"] as Int) != 0, createdAt: row["created_at"],
                             undone: (row["undone_by"] as String?) != nil, detail: OperationSummary.decodeDetail(row["detail_json"]))
        }
        return detail
    }

    /// The list, again after every change to the tables it reads.
    public func observeItems(status: Set<ItemStatus>, kinds: Set<KindFamily>? = nil, contextID: String?? = nil, review: Bool = false) -> AsyncStream<[ItemRow]> {
        let observation = ValueObservation.tracking { db in try Self.rows(db, status: status, kinds: kinds, contextID: contextID, review: review) }
        let pool = database.pool
        return AsyncStream { continuation in
            let task = Task {
                do { for try await rows in observation.values(in: pool) { continuation.yield(rows) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func rows(_ db: Database, status: Set<ItemStatus>, kinds: Set<KindFamily>?, contextID: String??, review: Bool = false) throws -> [ItemRow] {
        var clauses = ["i.status IN (\(status.map { _ in "?" }.joined(separator: ", ")))"]
        if review { clauses.append("i.needs_review = 1") }
        var arguments: [any DatabaseValueConvertible] = status.map(\.rawValue).sorted()
        if let kinds {
            clauses.append("i.family IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            arguments += kinds.map(\.rawValue).sorted()
        }
        if let contextID {
            if let id = contextID { clauses.append("i.context_id = ?"); arguments.append(id) } else { clauses.append("i.context_id IS NULL") }
        }
        let sql = """
            SELECT i.*,
                   (SELECT COUNT(*) FROM sightings s WHERE s.item_id = i.id) AS sighting_count,
                   EXISTS (SELECT 1 FROM field_locks l WHERE l.item_id = i.id) AS locked,
                   EXISTS (SELECT 1 FROM possible_duplicates p JOIN items o ON o.id = CASE WHEN p.item_a = i.id THEN p.item_b ELSE p.item_a END
                           WHERE (p.item_a = i.id OR p.item_b = i.id) AND o.status != 'merged') AS possible_duplicate
            FROM items i WHERE \(clauses.joined(separator: " AND "))
            ORDER BY COALESCE(i.start_at, i.due_at) IS NULL, COALESCE(i.start_at, i.due_at), i.title, i.id
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).compactMap { row in
            guard let item = Self.item(from: row) else { return nil }
            return ItemRow(item: item, sightingCount: row["sighting_count"], locked: (row["locked"] as Int) != 0,
                           possibleDuplicate: (row["possible_duplicate"] as Int) != 0)
        }
    }

    static func item(_ db: Database, id: String) throws -> Item? {
        try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]).flatMap(item(from:))
    }

    static func item(from row: Row) -> Item? {
        guard let kind = FindingKind(rawValue: row["kind"]), let status = ItemStatus(rawValue: row["status"]) else { return nil }
        let people = (row["people_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return Item(id: row["id"], kind: kind, status: status, mergedInto: row["merged_into"], contextID: row["context_id"], title: row["title"],
                    allDay: (row["all_day"] as Int) != 0, start: row["start_at"], end: row["end_at"], due: row["due_at"], remind: row["remind_at"],
                    timezone: row["timezone"], dayKey: row["day_key"], people: people, place: row["place"], notes: row["notes"],
                    confidence: row["confidence"], userTouched: (row["user_touched"] as Int) != 0, firstSeen: row["first_seen"], lastSeen: row["last_seen"],
                    needsReview: ((row["needs_review"] as Int?) ?? 0) != 0,
                    reviewReasons: ((row["review_reasons_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
                        .compactMap(ReviewReason.init(rawValue:)),
                    approvedAt: row["approved_at"])
    }

    /// After captures are deleted their sightings are gone: every item is built again from what is left, and an item with nothing left is
    /// removed unless the user edited, locked or dismissed it (FR-014). Cached title vectors nobody uses any more go too. Returns how many
    /// items were removed.
    @discardableResult
    public func sweep(at date: Date = Date()) throws -> Int {
        try database.pool.write { db in
            var removed = 0
            for id in try String.fetchAll(db, sql: "SELECT id FROM items WHERE status != 'merged'") {
                if try !Self.recompute(db, itemID: id, at: date) { removed += 1 }
            }
            try db.execute(sql: "DELETE FROM title_embeddings WHERE normalised NOT IN (SELECT normalised FROM item_aliases)")
            return removed
        }
    }

    // MARK: Writing (inside the caller's transaction)

    static func insert(_ db: Database, _ item: Item, at date: Date) throws {
        try db.execute(sql: """
            INSERT INTO items (id, kind, family, status, merged_into, context_id, title, all_day, start_at, end_at, due_at, remind_at, timezone,
                               day_key, people_json, place, notes, confidence, user_touched, first_seen, last_seen, needs_review,
                               review_reasons_json, approved_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments(values(for: item) + [date, date]))
    }

    /// Everything but the id and the creation time.
    static func update(_ db: Database, _ item: Item, at date: Date) throws {
        try db.execute(sql: """
            UPDATE items SET kind = ?, family = ?, status = ?, merged_into = ?, context_id = ?, title = ?, all_day = ?, start_at = ?, end_at = ?,
                due_at = ?, remind_at = ?, timezone = ?, day_key = ?, people_json = ?, place = ?, notes = ?, confidence = ?, user_touched = ?,
                first_seen = ?, last_seen = ?, needs_review = ?, review_reasons_json = ?, approved_at = ?, updated_at = ?
            WHERE id = ?
            """, arguments: StatementArguments(Array(values(for: item).dropFirst()) + [date, item.id]))
    }

    /// Marks the item approved as it reads now: the time, the values it vouches for, and the review state that follows from it.
    static func approve(_ db: Database, itemID: String, at date: Date) throws {
        guard var item = try Self.item(db, id: itemID) else { return }
        item.approvedAt = date
        item.userTouched = true
        try update(db, item, at: date)
        try setApprovalValues(db, itemID: itemID, ReviewRules.snapshot(of: item))
        try recompute(db, itemID: itemID, at: date)
    }

    /// The values an approval vouches for (`approved_values_json`); `update` does not write them.
    static func setApprovalValues(_ db: Database, itemID: String, _ values: [ItemField: JSONValue]?) throws {
        try db.execute(sql: "UPDATE items SET approved_values_json = ? WHERE id = ?", arguments: [values.map(ReviewRules.encode), itemID])
    }

    /// Takes an item's approval away, so the plain review rules judge it again.
    static func clearApproval(_ db: Database, itemID: String) throws {
        try db.execute(sql: "UPDATE items SET approved_at = NULL, approved_values_json = NULL WHERE id = ?", arguments: [itemID])
    }

    private static func values(for item: Item) -> [(any DatabaseValueConvertible)?] {
        let people = (try? JSONEncoder().encode(item.people)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let reasons = (try? JSONEncoder().encode(item.reviewReasons.map(\.rawValue))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let values: [(any DatabaseValueConvertible)?] = [
            item.id, item.kind.rawValue, item.family.rawValue, item.status.rawValue, item.mergedInto, item.contextID, item.title,
            item.allDay ? 1 : 0, item.start, item.end, item.due, item.remind, item.timezone, item.dayKey, people, item.place, item.notes,
            item.confidence, item.userTouched ? 1 : 0, item.firstSeen, item.lastSeen,
            item.needsReview ? 1 : 0, reasons, item.approvedAt,
        ]
        return values
    }
}
