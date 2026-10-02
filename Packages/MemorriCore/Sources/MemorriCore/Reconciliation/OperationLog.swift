import Foundation
import GRDB

public enum OperationKind: String, Sendable, Equatable, Codable {
    case autoMerge = "auto_merge", merge, split, dismiss, restore, edit, unlock, context, different, approve, undo
}

/// A sighting that changed item: `from` is nil when it joined an item as part of its own analysis.
public struct MovedSighting: Sendable, Equatable, Codable {
    public let sighting: String
    public let from: String?
    public let to: String

    public init(sighting: String, from: String?, to: String) { self.sighting = sighting; self.from = from; self.to = to }
}

/// What cannot be recomputed about an item and must be put back by an undo: its status, its place in a merge, whether the user
/// touched it, its locks and the user's own observations. Fields, aliases and times are derived again from the observations.
public struct ItemState: Sendable, Equatable, Codable {
    public var status: String
    public var mergedInto: String?
    public var userTouched: Bool
    /// Field name to the observation behind the lock.
    public var locks: [String: String]
    /// The ids of the user's own observations (those with no sighting) the item owned.
    public var observations: [String]
    /// The approval (spec 006): when, and the values it vouched for. Absent in entries written before it existed.
    public var approvedAt: Date?
    public var approvedValues: [String: JSONValue]?

    public init(status: String, mergedInto: String?, userTouched: Bool, locks: [String: String], observations: [String],
                approvedAt: Date? = nil, approvedValues: [String: JSONValue]? = nil) {
        self.status = status; self.mergedInto = mergedInto; self.userTouched = userTouched; self.locks = locks; self.observations = observations
        self.approvedAt = approvedAt; self.approvedValues = approvedValues
    }
}

/// One entry of the operation log.
public struct OperationRecord: Sendable, Equatable {
    public let id: String
    public let kind: OperationKind
    public let byUser: Bool
    public let itemIDs: [String]
    public let moved: [MovedSighting]
    public let before: [String: ItemState]
    public let detail: [String: JSONValue]
    public let undoneBy: String?
    public let createdAt: Date
}

/// Records and reads what was done to the items so any of it can be explained and undone (research R10).
public struct OperationLog: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    public func operation(id: String) throws -> OperationRecord? { try database.pool.read { try Self.fetch($0, id: id) } }

    /// The operations that touched an item, newest first.
    public func ops(forItem itemID: String) throws -> [OperationSummary] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.id, o.kind, o.by_user, o.created_at, o.undone_by FROM reconcile_ops o JOIN reconcile_op_items oi ON oi.op_id = o.id
                WHERE oi.item_id = ? ORDER BY o.created_at DESC, o.rowid DESC
                """, arguments: [itemID]).map { row in
                OperationSummary(id: row["id"], kind: row["kind"], byUser: (row["by_user"] as Int) != 0, createdAt: row["created_at"],
                                 undone: (row["undone_by"] as String?) != nil)
            }
        }
    }

    /// The newest operations of all items, newest first (the window's `Undo last` picks from these).
    public func recent(limit: Int = 100) throws -> [OperationSummary] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, by_user, created_at, undone_by FROM reconcile_ops ORDER BY created_at DESC, rowid DESC LIMIT ?",
                             arguments: [limit]).map { row in
                OperationSummary(id: row["id"], kind: row["kind"], byUser: (row["by_user"] as Int) != 0, createdAt: row["created_at"],
                                 undone: (row["undone_by"] as String?) != nil)
            }
        }
    }

    // MARK: Inside a transaction

    @discardableResult
    static func record(_ db: Database, kind: OperationKind, byUser: Bool, items: [String], moved: [MovedSighting] = [],
                       before: [String: ItemState] = [:], detail: [String: JSONValue] = [:], at date: Date) throws -> String {
        let id = UUID().uuidString
        let unique = Array(NSOrderedSet(array: items)) as? [String] ?? items
        try db.execute(sql: """
            INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """, arguments: [id, kind.rawValue, byUser ? 1 : 0, encode(unique), encode(moved), encode(before), encode(detail), date])
        for item in unique {
            try db.execute(sql: "INSERT INTO reconcile_op_items (op_id, item_id) VALUES (?, ?)", arguments: [id, item])
        }
        return id
    }

    static func fetch(_ db: Database, id: String) throws -> OperationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM reconcile_ops WHERE id = ?", arguments: [id]),
              let kind = OperationKind(rawValue: row["kind"]) else { return nil }
        return OperationRecord(id: id, kind: kind, byUser: (row["by_user"] as Int) != 0,
                               itemIDs: decode(row["item_ids_json"]) ?? [], moved: decode(row["moved_json"]) ?? [],
                               before: decode(row["before_json"]) ?? [:], detail: decode(row["detail_json"]) ?? [:],
                               undoneBy: row["undone_by"], createdAt: row["created_at"])
    }

    /// The state an undo has to restore for an item; nil when it does not exist.
    static func state(_ db: Database, itemID: String) throws -> ItemState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT status, merged_into, user_touched, approved_at, approved_values_json FROM items WHERE id = ?", arguments: [itemID]) else { return nil }
        var locks: [String: String] = [:]
        for lock in try Row.fetchAll(db, sql: "SELECT field, observation_id FROM field_locks WHERE item_id = ?", arguments: [itemID]) {
            locks[lock["field"]] = lock["observation_id"]
        }
        let own = try String.fetchAll(db, sql: "SELECT id FROM observations WHERE item_id = ? AND sighting_id IS NULL ORDER BY id", arguments: [itemID])
        let values = (row["approved_values_json"] as String?).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }
        return ItemState(status: row["status"], mergedInto: row["merged_into"], userTouched: (row["user_touched"] as Int) != 0, locks: locks, observations: own,
                         approvedAt: row["approved_at"], approvedValues: values)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static func decode<T: Decodable>(_ text: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(text.utf8)) }
}
