import Foundation
import GRDB

extension ItemOperations {
    // MARK: Merge

    /// Joins `other` into `keep`: every sighting, observation, alias and lock goes to `keep`, `other` is recorded as merged into it.
    /// When both have a locked value for a field, `lockChoices[field]` names the item (`keep` or `other`) whose value stays; without a
    /// choice the call throws `needsLockChoice` and changes nothing (FR-013).
    @discardableResult
    public func merge(_ keep: String, _ other: String, lockChoices: [ItemField: String] = [:]) throws -> OpID {
        guard keep != other else { throw ItemOperationError.sameItem }
        let date = now()
        return try database.pool.write { db in
            var kept = try Self.live(db, keep)
            var gone = try Self.live(db, other)
            let beforeKeep = try OperationLog.state(db, itemID: keep)!, beforeOther = try OperationLog.state(db, itemID: other)!

            // Fields locked on both sides with different values need the user's choice.
            var conflicts: [ItemField] = []
            var winners: [ItemField: String] = [:]
            for (name, keepLock) in beforeKeep.locks {
                guard let field = ItemField(rawValue: name), let otherLock = beforeOther.locks[name] else { continue }
                let a = try Self.value(db, observation: keepLock), b = try Self.value(db, observation: otherLock)
                if a == b { winners[field] = keep; continue }
                guard let choice = lockChoices[field] else { conflicts.append(field); continue }
                guard choice == keep || choice == other else { throw ItemOperationError.invalidValue }
                winners[field] = choice
            }
            if !conflicts.isEmpty { throw ItemOperationError.needsLockChoice(conflicts.sorted { $0.rawValue < $1.rawValue }) }

            // Sightings (their observations follow), the user's own observations and the locks move to the survivor.
            let sightings = try String.fetchAll(db, sql: "SELECT id FROM sightings WHERE item_id = ? ORDER BY created_at, id", arguments: [other])
            let moved = sightings.map { MovedSighting(sighting: $0, from: other, to: keep) }
            try Self.move(db, sightings: sightings, to: keep)
            try db.execute(sql: "UPDATE observations SET item_id = ? WHERE item_id = ?", arguments: [keep, other])
            for name in beforeOther.locks.keys {
                guard let field = ItemField(rawValue: name) else { continue }
                if beforeKeep.locks[name] == nil || winners[field] == other {
                    try db.execute(sql: "DELETE FROM field_locks WHERE item_id = ? AND field = ?", arguments: [keep, name])
                    try db.execute(sql: "UPDATE field_locks SET item_id = ? WHERE item_id = ? AND field = ?", arguments: [keep, other, name])
                } else {
                    try db.execute(sql: "DELETE FROM field_locks WHERE item_id = ? AND field = ?", arguments: [other, name])
                }
            }
            let pair = [keep, other].sorted()
            let possible = try String.fetchOne(db, sql: "SELECT scores_json FROM possible_duplicates WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])
            try db.execute(sql: "DELETE FROM possible_duplicates WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])

            gone.status = .merged
            gone.mergedInto = keep
            gone.userTouched = true
            kept.userTouched = true
            try ItemStore.update(db, gone, at: date)
            try ItemStore.update(db, kept, at: date)
            try ItemStore.recompute(db, itemID: keep, at: date)
            let choices = Dictionary(uniqueKeysWithValues: winners.filter { lockChoices[$0.key] != nil }.map { ($0.key.rawValue, JSONValue.string($0.value)) })
            return try OperationLog.record(db, kind: .merge, byUser: true, items: [keep, other], moved: moved, before: [keep: beforeKeep, other: beforeOther],
                                           detail: ["keep": .string(keep), "other": .string(other), "lockChoices": .object(choices),
                                                    "possible": possible.map(JSONValue.string) ?? .null], at: date)
        }
    }

    // MARK: Split

    /// Takes the chosen sightings out of an item into a new one. The two are remembered as different, so nothing joins them again
    /// by itself (FR-012).
    @discardableResult
    public func split(_ itemID: String, sightings chosen: [String]) throws -> (op: OpID, newItem: String) {
        let date = now()
        return try database.pool.write { db in
            let item = try Self.live(db, itemID)
            let all = try String.fetchAll(db, sql: "SELECT id FROM sightings WHERE item_id = ?", arguments: [itemID])
            let picked = Array(NSOrderedSet(array: chosen)) as? [String] ?? chosen
            guard !picked.isEmpty, picked.allSatisfy(all.contains), picked.count < all.count else { throw ItemOperationError.invalidSightings }
            let before = try OperationLog.state(db, itemID: itemID)!
            let created = try Self.makeItem(db, like: item, at: date)
            try Self.move(db, sightings: picked, to: created.id)
            try ItemStore.recompute(db, itemID: itemID, at: date)
            try ItemStore.recompute(db, itemID: created.id, at: date)
            let op = try OperationLog.record(db, kind: .split, byUser: true, items: [itemID, created.id],
                                             moved: picked.map { MovedSighting(sighting: $0, from: itemID, to: created.id) }, before: [itemID: before],
                                             detail: ["new": .string(created.id), "created": .array([.string(created.id)])], at: date)
            try Self.keepApart(db, itemID, created.id, op: op)
            return (op, created.id)
        }
    }

    // MARK: Different

    /// "These are not the same": clears the possible duplicate and keeps the two apart.
    @discardableResult
    public func markDifferent(_ a: String, _ b: String) throws -> OpID {
        guard a != b else { throw ItemOperationError.sameItem }
        let date = now()
        return try database.pool.write { db in
            _ = try Self.live(db, a); _ = try Self.live(db, b)
            let pair = [a, b].sorted()
            let scores = try String.fetchOne(db, sql: "SELECT scores_json FROM possible_duplicates WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])
            try db.execute(sql: "DELETE FROM possible_duplicates WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])
            let op = try OperationLog.record(db, kind: .different, byUser: true, items: pair, detail: ["scores": scores.map(JSONValue.string) ?? .null], at: date)
            try Self.keepApart(db, a, b, op: op)
            return op
        }
    }

    // MARK: Helpers

    static func value(_ db: Database, observation id: String) throws -> JSONValue? {
        try String.fetchOne(db, sql: "SELECT value_json FROM observations WHERE id = ?", arguments: [id])
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// Moves sightings, and the observations and evidence that belong to them, to another item.
    static func move(_ db: Database, sightings: [String], to itemID: String) throws {
        for id in sightings {
            try db.execute(sql: "UPDATE sightings SET item_id = ? WHERE id = ?", arguments: [itemID, id])
            try db.execute(sql: "UPDATE observations SET item_id = ? WHERE sighting_id = ?", arguments: [itemID, id])
            try db.execute(sql: "UPDATE evidence SET item_id = ? WHERE sighting_id = ?", arguments: [itemID, id])
        }
    }

    /// A new item shaped like `item`, the user's own (so it is not swept away while empty); `recompute` fills it in.
    static func makeItem(_ db: Database, like item: Item, at date: Date) throws -> Item {
        let created = Item(kind: item.kind, contextID: item.contextID, title: item.title, timezone: item.timezone, confidence: item.confidence,
                           userTouched: true, firstSeen: item.firstSeen, lastSeen: item.lastSeen)
        try ItemStore.insert(db, created, at: date)
        return created
    }

    static func keepApart(_ db: Database, _ a: String, _ b: String, op: String) throws {
        let pair = [a, b].sorted()
        try db.execute(sql: "INSERT OR REPLACE INTO keep_apart (item_a, item_b, op_id) VALUES (?, ?, ?)", arguments: [pair[0], pair[1], op])
    }
}
