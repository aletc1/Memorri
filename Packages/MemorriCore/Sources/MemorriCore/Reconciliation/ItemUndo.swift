import Foundation
import GRDB

public enum UndoResult: Sendable, Equatable {
    case undone(OpID)
    /// Some of it could not be put back, with why (a later change touched the same items, or a capture is gone).
    case partly(OpID, reason: String)
    case impossible(reason: String)
}

extension ItemOperations {
    // MARK: Change a picture's context

    /// The user picks another context for a picture: its sightings are matched again in the new context (research R12a).
    @discardableResult
    public func changeContext(imageID: String, to contextID: String?) async throws -> OpID {
        guard let reconciler else { throw ItemOperationError.noReconciler }
        struct Previous: Sendable { let context: String?; let source: String }
        let previous: Previous? = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT context_id, source FROM image_context WHERE image_id = ?", arguments: [imageID])
                .map { Previous(context: $0["context_id"], source: $0["source"]) }
        }
        let from = previous?.context, fromSource = previous?.source ?? "none"
        try ContextStore(database: database).setUserChoice(imageID: imageID, contextID: contextID, at: now())
        _ = await reconciler.reconcile(imageID: imageID)
        let date = now()
        return try await database.pool.write { db in
            try OperationLog.record(db, kind: .context, byUser: true, items: [], detail: [
                "image": .string(imageID), "from": from.map(JSONValue.string) ?? .null, "fromSource": .string(fromSource),
                "to": contextID.map(JSONValue.string) ?? .null,
            ], at: date)
        }
    }

    // MARK: Undo

    /// Puts back what an operation did, as far as later changes allow (research R10). The undo is itself an operation and can be undone.
    public func undo(_ opID: OpID) async throws -> UndoResult {
        let outcome = try await database.pool.write { db in try self.undoInside(db, opID) }
        if let followUp = outcome.reconcile, let reconciler { _ = await reconciler.reconcile(imageID: followUp) }
        for imageID in outcome.evidence { _ = await evidence?.write(imageID: imageID) }
        return outcome.result
    }

    struct UndoOutcome { var result: UndoResult; var reconcile: String?; var evidence: [String] = [] }

    private func undoInside(_ db: Database, _ opID: OpID) throws -> UndoOutcome {
        guard let op = try OperationLog.fetch(db, id: opID) else { return UndoOutcome(result: .impossible(reason: "operation not found")) }
        guard op.undoneBy == nil else { return UndoOutcome(result: .impossible(reason: "already undone")) }
        let date = now()
        let rowid = try Int.fetchOne(db, sql: "SELECT rowid FROM reconcile_ops WHERE id = ?", arguments: [opID]) ?? 0

        var skipped: [String] = []
        var didSomething = false
        var touched: [String] = []
        func touch(_ id: String) { if !touched.contains(id) { touched.append(id) } }
        var undoMoves: [MovedSighting] = []
        var created: [String] = []

        // What the undo itself will have to be able to undo.
        var before: [String: ItemState] = [:]
        for id in op.itemIDs + op.moved.compactMap(\.from) + op.moved.map(\.to) { if before[id] == nil, let s = try OperationLog.state(db, itemID: id) { before[id] = s } }

        func laterLive(_ item: String) throws -> Bool {
            // The undo of a change made after this one cancels that change out, so it does not count; neither does a later sighting joining
            // the item (an automatic merge changes no state that this undo puts back).
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM reconcile_ops o JOIN reconcile_op_items oi ON oi.op_id = o.id
                               WHERE oi.item_id = ?1 AND o.rowid > ?2 AND o.undone_by IS NULL AND o.id != ?3 AND o.kind != 'auto_merge'
                                 AND NOT (o.kind = 'undo' AND EXISTS (SELECT 1 FROM reconcile_ops u WHERE u.undone_by = o.id AND u.rowid > ?2)))
                """, arguments: [item, rowid, opID]) ?? false
        }

        // 1. The sightings go back where they came from.
        var groups: [String: [MovedSighting]] = [:]
        var order: [String] = []
        for move in op.moved {
            let key = move.from ?? "\u{0}new:\(move.sighting)"        // a sighting that joined by itself is separated on its own
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(move)
        }
        for key in order {
            let moves = groups[key]!
            var present: [MovedSighting] = []
            for move in moves {
                guard let holder = try String.fetchOne(db, sql: "SELECT item_id FROM sightings WHERE id = ?", arguments: [move.sighting]) else {
                    skipped.append("a capture that showed it was deleted"); continue
                }
                if holder != move.to { skipped.append("a later change moved a sighting"); continue }
                present.append(move)
            }
            guard let first = present.first, let current = try ItemStore.item(db, id: first.to) else { continue }
            var destination: String?
            // The item they came from, also when it is merged away right now and this very undo brings it back.
            if let from = moves.first?.from, let item = try ItemStore.item(db, id: from),
               item.status != .merged || (op.before[from].map { $0.status != ItemStatus.merged.rawValue } ?? false) { destination = from }
            let target: String
            if let destination { target = destination } else {
                let made = try Self.makeItem(db, like: current, at: date)
                created.append(made.id)
                target = made.id
                if moves.first?.from == nil { try Self.keepApart(db, first.to, made.id, op: opID) }
            }
            try Self.move(db, sightings: present.map(\.sighting), to: target)
            for move in present { undoMoves.append(MovedSighting(sighting: move.sighting, from: move.to, to: target)); touch(move.to) }
            touch(target)
            didSomething = true
        }

        // Nothing could be put back because every sighting it moved is gone: there is nothing left to undo.
        if !op.moved.isEmpty && undoMoves.isEmpty {
            return UndoOutcome(result: .impossible(reason: skipped.first ?? "the sightings are gone"), reconcile: nil)
        }

        // 2. Status, locks and the user's own observations of the items the operation changed.
        var restored: Set<String> = []
        for (itemID, state) in op.before.sorted(by: { $0.key < $1.key }) {
            guard try ItemStore.item(db, id: itemID) != nil else { continue }
            if try laterLive(itemID) { skipped.append("a later change touched the same item"); continue }
            for observation in state.observations {
                try db.execute(sql: "UPDATE observations SET item_id = ? WHERE id = ? AND sighting_id IS NULL", arguments: [itemID, observation])
            }
            try db.execute(sql: "DELETE FROM field_locks WHERE item_id = ?", arguments: [itemID])
            for (field, observation) in state.locks.sorted(by: { $0.key < $1.key }) {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM observations WHERE id = ?)", arguments: [observation]) ?? false
                if exists {
                    try db.execute(sql: "INSERT INTO field_locks (item_id, field, observation_id, locked_at) VALUES (?, ?, ?, ?)", arguments: [itemID, field, observation, date])
                }
            }
            try db.execute(sql: "UPDATE items SET status = ?, merged_into = ?, user_touched = ?, approved_at = ?, approved_values_json = ?, updated_at = ? WHERE id = ?",
                           arguments: [state.status, state.mergedInto, state.userTouched ? 1 : 0, state.approvedAt,
                                       state.approvedValues.map { ReviewRules.encode(Dictionary(uniqueKeysWithValues: $0.compactMap { name, value in ItemField(rawValue: name).map { ($0, value) } })) },
                                       date, itemID])
            restored.insert(itemID)
            touch(itemID)
            didSomething = true
        }

        // 3. What is particular to the kind.
        var reconcileImage: String?
        var evidenceImages: [String] = []
        switch op.kind {
        case .edit:
            if case .string(let observation)? = op.detail["observation"], let item = op.itemIDs.first, restored.contains(item) {
                try db.execute(sql: "DELETE FROM observations WHERE id = ? AND sighting_id IS NULL", arguments: [observation])
            }
        case .merge:
            let pair = op.itemIDs.sorted()
            if pair.count == 2, case .string(let scores)? = op.detail["possible"], restored.count == 2 {
                try db.execute(sql: "INSERT OR IGNORE INTO possible_duplicates (item_a, item_b, scores_json, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [pair[0], pair[1], scores, date])
                touch(pair[0]); touch(pair[1])
            }
        case .different:
            let pair = op.itemIDs.sorted()
            if pair.count == 2 {
                try db.execute(sql: "DELETE FROM keep_apart WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])
                if case .string(let scores)? = op.detail["scores"] {
                    try db.execute(sql: "INSERT OR IGNORE INTO possible_duplicates (item_a, item_b, scores_json, created_at) VALUES (?, ?, ?, ?)",
                                   arguments: [pair[0], pair[1], scores, date])
                }
                touch(pair[0]); touch(pair[1])
                didSomething = true
            }
        case .undo:
            // Undoing an undo does again what the first operation did to the pair's bookkeeping.
            if case .string(let inner)? = op.detail["undone"], let first = try OperationLog.fetch(db, id: inner) {
                let pair = first.itemIDs.sorted()
                if pair.count == 2, first.kind == .merge || first.kind == .different {
                    try db.execute(sql: "DELETE FROM possible_duplicates WHERE item_a = ? AND item_b = ?", arguments: [pair[0], pair[1]])
                    if first.kind == .different { try Self.keepApart(db, pair[0], pair[1], op: opID) }
                    touch(pair[0]); touch(pair[1])
                }
            }
        case .context:
            if case .string(let image)? = op.detail["image"] {
                let from: String? = op.detail["from"]?.asString
                let source = op.detail["fromSource"]?.asString ?? "none"
                try db.execute(sql: "UPDATE image_context SET context_id = ?, source = ?, decided_at = ? WHERE image_id = ?", arguments: [from, source, date, image])
                reconcileImage = image
                didSomething = true
            }
        case .applyTrial:
            // The sightings the apply added go; the ones it removed come back, with their observations, under their old ids.
            var blocked: Set<String> = []
            func blockedItem(_ id: String) throws -> Bool {
                if blocked.contains(id) { return true }
                if try laterLive(id) { blocked.insert(id); skipped.append("a later change touched the same item"); return true }
                return false
            }
            if case .array(let ids)? = op.detail["sightings"] {
                for case .string(let sighting) in ids {
                    guard let item = try String.fetchOne(db, sql: "SELECT item_id FROM sightings WHERE id = ?", arguments: [sighting]) else { continue }
                    if try blockedItem(item) { continue }
                    try db.execute(sql: "DELETE FROM sightings WHERE id = ?", arguments: [sighting])
                    touch(item)
                    didSomething = true
                }
            }
            if case .array(let images)? = op.detail["images"] { evidenceImages = images.compactMap(\.asString) }
            if case .array(let entries)? = op.detail["removed"] {
                // The sightings this very undo puts back are not "read again since", so they are told apart by id.
                var removedIDs: [String] = []
                for entry in entries { if case .object(let row)? = entry["sighting"], case .string(let id)? = row["id"] { removedIDs.append(id) } }
                // What the capture still showed when the apply was made counts as known too; anything else is a sighting made since.
                if case .array(let kept)? = op.detail["kept"] { removedIDs += kept.compactMap(\.asString) }
                for entry in entries {
                    guard case .string(let item)? = entry["item"], case .object(let sighting)? = entry["sighting"],
                          try ItemStore.item(db, id: item) != nil else { continue }
                    if try blockedItem(item) { continue }
                    // A capture read again since (a context change, a reanalysis, the library re-read) shows this item with sightings of its own:
                    // putting the old one back next to them would count the same reading twice.
                    if case .string(let image)? = sighting["image_id"],
                       try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sightings WHERE image_id = ? AND item_id = ? AND id NOT IN (\(removedIDs.map { _ in "?" }.joined(separator: ", "))))",
                                         arguments: StatementArguments([image, item] + removedIDs)) == true {
                        skipped.append("the capture was read again since")
                        continue
                    }
                    func insert(_ table: String, _ row: [String: JSONValue]) throws {
                        let columns = row.keys.sorted()
                        let values: [DatabaseValue] = columns.map { column in
                            switch row[column]! {
                            case .string(let text): text.databaseValue
                            case .int(let n): n.databaseValue
                            case .double(let x): x.databaseValue
                            case .bool(let flag): (flag ? 1 : 0).databaseValue
                            default: .null
                            }
                        }
                        try db.execute(sql: "INSERT OR REPLACE INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                                       arguments: StatementArguments(values))
                    }
                    try insert("sightings", sighting)
                    if case .array(let observations)? = entry["observations"] {
                        for case .object(let row) in observations { try insert("observations", row) }
                    }
                    touch(item)
                    didSomething = true
                }
            }
        default: break
        }
        // Items the operation made are removed once nothing is left in them.
        if case .array(let ids)? = op.detail["created"] {
            for case .string(let id) in ids {
                let empty = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sightings WHERE item_id = ?", arguments: [id]) ?? 0) == 0
                if empty, try ItemStore.item(db, id: id) != nil { try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id]); didSomething = true }
            }
        }

        guard didSomething else { return UndoOutcome(result: .impossible(reason: skipped.first ?? "nothing to undo"), reconcile: nil) }
        for id in touched { try ItemStore.recompute(db, itemID: id, at: date) }
        var detail: [String: JSONValue] = ["undone": .string(opID)]
        if !created.isEmpty { detail["created"] = .array(created.map(JSONValue.string)) }
        let reasons = Array(NSOrderedSet(array: skipped)) as? [String] ?? skipped
        if !reasons.isEmpty { detail["skipped"] = .array(reasons.map(JSONValue.string)) }
        var existing: [String] = []
        for id in touched where try ItemStore.item(db, id: id) != nil { existing.append(id) }
        let undoID = try OperationLog.record(db, kind: .undo, byUser: true, items: existing, moved: undoMoves,
                                             before: before.filter { touched.contains($0.key) }, detail: detail, at: date)
        try db.execute(sql: "UPDATE reconcile_ops SET undone_by = ? WHERE id = ?", arguments: [undoID, opID])
        return UndoOutcome(result: reasons.isEmpty ? .undone(undoID) : .partly(undoID, reason: reasons.joined(separator: "; ")), reconcile: reconcileImage, evidence: evidenceImages)
    }
}
