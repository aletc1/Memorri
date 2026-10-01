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
}

/// Reads and writes the item tables. The reconciler and the operations use the static helpers inside their own transactions.
public struct ItemStore: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    // MARK: Reading

    /// `contextID`: nil for any context, `.some(nil)` for items without one, `.some(id)` for one context.
    public func items(status: Set<ItemStatus>, kinds: Set<KindFamily>?, contextID: String??) throws -> [ItemRow] {
        try database.pool.read { try Self.rows($0, status: status, kinds: kinds, contextID: contextID) }
    }

    public func item(id: String) throws -> Item? {
        try database.pool.read { try Self.item($0, id: id) }
    }

    public func detail(itemID: String) throws -> ItemDetail {
        try database.pool.read { db in
            guard let item = try Self.item(db, id: itemID) else { throw ItemStoreError.notFound }
            return ItemDetail(item: item)
        }
    }

    /// The list, again after every change to the tables it reads.
    public func observeItems(status: Set<ItemStatus>, kinds: Set<KindFamily>? = nil, contextID: String?? = nil) -> AsyncStream<[ItemRow]> {
        let observation = ValueObservation.tracking { db in try Self.rows(db, status: status, kinds: kinds, contextID: contextID) }
        let pool = database.pool
        return AsyncStream { continuation in
            let task = Task {
                do { for try await rows in observation.values(in: pool) { continuation.yield(rows) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func rows(_ db: Database, status: Set<ItemStatus>, kinds: Set<KindFamily>?, contextID: String??) throws -> [ItemRow] {
        var clauses = ["i.status IN (\(status.map { _ in "?" }.joined(separator: ", ")))"]
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
                   EXISTS (SELECT 1 FROM possible_duplicates p WHERE p.item_a = i.id OR p.item_b = i.id) AS possible_duplicate
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
                    confidence: row["confidence"], userTouched: (row["user_touched"] as Int) != 0, firstSeen: row["first_seen"], lastSeen: row["last_seen"])
    }

    // MARK: Writing (inside the caller's transaction)

    static func insert(_ db: Database, _ item: Item, at date: Date) throws {
        try db.execute(sql: """
            INSERT INTO items (id, kind, family, status, merged_into, context_id, title, all_day, start_at, end_at, due_at, remind_at, timezone,
                               day_key, people_json, place, notes, confidence, user_touched, first_seen, last_seen, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments(values(for: item) + [date, date]))
    }

    /// Everything but the id and the creation time.
    static func update(_ db: Database, _ item: Item, at date: Date) throws {
        try db.execute(sql: """
            UPDATE items SET kind = ?, family = ?, status = ?, merged_into = ?, context_id = ?, title = ?, all_day = ?, start_at = ?, end_at = ?,
                due_at = ?, remind_at = ?, timezone = ?, day_key = ?, people_json = ?, place = ?, notes = ?, confidence = ?, user_touched = ?,
                first_seen = ?, last_seen = ?, updated_at = ?
            WHERE id = ?
            """, arguments: StatementArguments(Array(values(for: item).dropFirst()) + [date, item.id]))
    }

    private static func values(for item: Item) -> [(any DatabaseValueConvertible)?] {
        let people = (try? JSONEncoder().encode(item.people)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let values: [(any DatabaseValueConvertible)?] = [
            item.id, item.kind.rawValue, item.family.rawValue, item.status.rawValue, item.mergedInto, item.contextID, item.title,
            item.allDay ? 1 : 0, item.start, item.end, item.due, item.remind, item.timezone, item.dayKey, people, item.place, item.notes,
            item.confidence, item.userTouched ? 1 : 0, item.firstSeen, item.lastSeen,
        ]
        return values
    }
}
