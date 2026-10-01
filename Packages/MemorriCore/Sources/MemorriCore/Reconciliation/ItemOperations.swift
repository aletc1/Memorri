import Foundation
import GRDB

public typealias OpID = String

public enum ItemOperationError: Error, Equatable {
    case notFound
    /// The item was merged into another; act on the survivor.
    case merged
    case notLocked
    /// The status does not allow it (dismissing a dismissed item).
    case wrongStatus
    case invalidValue
    /// Both items have a locked value for these fields; say which to keep.
    case needsLockChoice([ItemField])
    /// The sightings do not belong to the item, or would leave it empty, or take all of it.
    case invalidSightings
    /// An item cannot be merged into itself.
    case sameItem
    /// This operation needs the reconciler, which was not given.
    case noReconciler
}

/// What the user can do to an item. Each operation runs in one transaction and writes an entry of the operation log with what an
/// undo needs (research R10).
public struct ItemOperations: Sendable {
    let database: StorageDatabase
    let now: @Sendable () -> Date
    let reconciler: (any ImageReconciling)?

    /// `reconciler` is needed only by `changeContext` and by the undo of a context change.
    public init(database: StorageDatabase, reconciler: (any ImageReconciling)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.reconciler = reconciler; self.now = now
    }

    /// Sets a field to the user's value and locks it: later sightings are recorded but never change it.
    @discardableResult
    public func edit(_ itemID: String, field: ItemField, value: JSONValue) throws -> OpID {
        guard Self.isValid(value, for: field) else { throw ItemOperationError.invalidValue }
        let date = now()
        return try database.pool.write { db in
            var item = try Self.live(db, itemID)
            let before = try OperationLog.state(db, itemID: itemID)!
            let observationID = UUID().uuidString
            let json = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            try db.execute(sql: """
                INSERT INTO observations (id, item_id, sighting_id, field, value_json, source, confidence, observed_at)
                VALUES (?, ?, NULL, ?, ?, 'user', 1, ?)
                """, arguments: [observationID, itemID, field.rawValue, json, date])
            try db.execute(sql: "INSERT OR REPLACE INTO field_locks (item_id, field, observation_id, locked_at) VALUES (?, ?, ?, ?)",
                           arguments: [itemID, field.rawValue, observationID, date])
            item.userTouched = true
            try ItemStore.update(db, item, at: date)
            try ItemStore.recompute(db, itemID: itemID, at: date)
            return try OperationLog.record(db, kind: .edit, byUser: true, items: [itemID], before: [itemID: before],
                                           detail: ["field": .string(field.rawValue), "observation": .string(observationID)], at: date)
        }
    }

    /// Takes the lock off a field: it follows the observations again. The user's value stays as history.
    @discardableResult
    public func unlock(_ itemID: String, field: ItemField) throws -> OpID {
        let date = now()
        return try database.pool.write { db in
            _ = try Self.live(db, itemID)
            let before = try OperationLog.state(db, itemID: itemID)!
            guard before.locks[field.rawValue] != nil else { throw ItemOperationError.notLocked }
            try db.execute(sql: "DELETE FROM field_locks WHERE item_id = ? AND field = ?", arguments: [itemID, field.rawValue])
            try ItemStore.recompute(db, itemID: itemID, at: date)
            return try OperationLog.record(db, kind: .unlock, byUser: true, items: [itemID], before: [itemID: before],
                                           detail: ["field": .string(field.rawValue)], at: date)
        }
    }

    /// The user checked the item: it leaves the Inbox and stays approved until a later sighting changes what was approved (FR-012).
    @discardableResult
    public func approve(_ itemID: String) throws -> OpID {
        let date = now()
        return try database.pool.write { db in
            var item = try Self.live(db, itemID)
            guard item.status == .active else { throw ItemOperationError.wrongStatus }
            let before = try OperationLog.state(db, itemID: itemID)!
            item.approvedAt = date
            item.userTouched = true
            try ItemStore.update(db, item, at: date)
            try ItemStore.setApprovalValues(db, itemID: itemID, ReviewRules.snapshot(of: item))
            try ItemStore.recompute(db, itemID: itemID, at: date)
            return try OperationLog.record(db, kind: .approve, byUser: true, items: [itemID], before: [itemID: before], at: date)
        }
    }

    /// The item is remembered, hidden, and still collects sightings of the same event.
    @discardableResult
    public func dismiss(_ itemID: String) throws -> OpID { try setStatus(itemID, from: .active, to: .dismissed, kind: .dismiss) }

    @discardableResult
    public func restore(_ itemID: String) throws -> OpID { try setStatus(itemID, from: .dismissed, to: .active, kind: .restore) }

    private func setStatus(_ itemID: String, from: ItemStatus, to: ItemStatus, kind: OperationKind) throws -> OpID {
        let date = now()
        return try database.pool.write { db in
            var item = try Self.live(db, itemID)
            guard item.status == from else { throw ItemOperationError.wrongStatus }
            let before = try OperationLog.state(db, itemID: itemID)!
            item.status = to
            item.userTouched = true
            try ItemStore.update(db, item, at: date)
            try ItemStore.recompute(db, itemID: itemID, at: date)         // a dismissed item needs no review; a restored one may
            return try OperationLog.record(db, kind: kind, byUser: true, items: [itemID], before: [itemID: before], at: date)
        }
    }

    /// The item, or why it cannot be acted on.
    static func live(_ db: Database, _ id: String) throws -> Item {
        guard let item = try ItemStore.item(db, id: id) else { throw ItemOperationError.notFound }
        guard item.status != .merged else { throw ItemOperationError.merged }
        return item
    }

    static func isValid(_ value: JSONValue, for field: ItemField) -> Bool {
        switch field {
        case .title: if let text = value.asString { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false }
        case .start, .end, .due, .remind: value.asDate != nil
        case .allDay: value.asBool != nil
        case .people: value.asStrings != nil
        case .place, .notes: value.asString != nil
        }
    }
}
