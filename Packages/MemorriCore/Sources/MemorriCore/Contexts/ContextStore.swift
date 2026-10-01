import Foundation
import GRDB

/// What one hint of a context looks for.
public struct ContextHint: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case windowTitle = "window_title", app, domain, keyword }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }
}

/// A customer, remote session or workspace, with the hints that tell its pictures and the time zone its dates use.
public struct ContextRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// An IANA identifier, or nil for the Mac's own zone.
    public var timezone: String?
    public var hints: [ContextHint]

    public init(id: String, name: String, timezone: String?, hints: [ContextHint]) {
        self.id = id; self.name = name; self.timezone = timezone; self.hints = hints
    }
}

public enum ContextError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyName
    case nameInUse
    case invalidTimezone
    case hintTooShort

    /// The text Settings shows.
    public var description: String {
        switch self {
        case .emptyName: "Enter a name."
        case .nameInUse: "That name is already used."
        case .invalidTimezone: "That is not a time zone."
        case .hintTooShort: "Enter at least 2 characters."
        }
    }
}

/// The user's contexts and the context each picture was given. The rules (unique names, known zones, hints of at least two
/// characters) live here so every screen obeys them.
public struct ContextStore: Sendable {
    public static let minimumHintLength = 2

    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    // MARK: Reading

    public func all() throws -> [ContextRecord] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM contexts ORDER BY lower(name), id").map { row in
                let id: String = row["id"]
                let hints = try Row.fetchAll(db, sql: "SELECT kind, value FROM context_hints WHERE context_id = ? ORDER BY rowid", arguments: [id]).compactMap { hint -> ContextHint? in
                    ContextHint.Kind(rawValue: hint["kind"]).map { ContextHint(kind: $0, value: hint["value"]) }
                }
                return ContextRecord(id: id, name: row["name"], timezone: row["timezone"], hints: hints)
            }
        }
    }

    // MARK: Writing

    private func checked(name: String, timezone: String?, hints: [ContextHint]) throws -> (name: String, timezone: String?, hints: [ContextHint]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContextError.emptyName }
        if let timezone, TimeZone(identifier: timezone) == nil { throw ContextError.invalidTimezone }
        let clean = try hints.map { hint -> ContextHint in
            let value = hint.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= Self.minimumHintLength else { throw ContextError.hintTooShort }
            return ContextHint(kind: hint.kind, value: value)
        }
        return (trimmed, timezone, clean)
    }

    private func nameInUse(_ db: Database, _ name: String, except id: String?) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contexts WHERE lower(name) = lower(?) AND id != ?", arguments: [name, id ?? ""]) ?? 0 > 0
    }

    private func writeHints(_ db: Database, _ hints: [ContextHint], contextID: String) throws {
        try db.execute(sql: "DELETE FROM context_hints WHERE context_id = ?", arguments: [contextID])
        for hint in hints {
            try db.execute(sql: "INSERT INTO context_hints (id, context_id, kind, value) VALUES (?, ?, ?, ?)",
                           arguments: [UUID().uuidString, contextID, hint.kind.rawValue, hint.value])
        }
    }

    @discardableResult
    public func add(name: String, timezone: String?, hints: [ContextHint], at date: Date = Date()) throws -> ContextRecord {
        let valid = try checked(name: name, timezone: timezone, hints: hints)
        let id = UUID().uuidString
        try database.pool.write { db in
            guard try !nameInUse(db, valid.name, except: nil) else { throw ContextError.nameInUse }
            try db.execute(sql: "INSERT INTO contexts (id, name, timezone, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [id, valid.name, valid.timezone, date, date])
            try writeHints(db, valid.hints, contextID: id)
        }
        return ContextRecord(id: id, name: valid.name, timezone: valid.timezone, hints: valid.hints)
    }

    public func update(_ context: ContextRecord, at date: Date = Date()) throws {
        let valid = try checked(name: context.name, timezone: context.timezone, hints: context.hints)
        try database.pool.write { db in
            guard try !nameInUse(db, valid.name, except: context.id) else { throw ContextError.nameInUse }
            try db.execute(sql: "UPDATE contexts SET name = ?, timezone = ?, updated_at = ? WHERE id = ?",
                           arguments: [valid.name, valid.timezone, date, context.id])
            try writeHints(db, valid.hints, contextID: context.id)
        }
    }

    /// Pictures that had this context become unassigned; their findings stay.
    public func delete(id: String) throws {
        try database.pool.write { try $0.execute(sql: "DELETE FROM contexts WHERE id = ?", arguments: [id]) }
    }

    // MARK: A picture's context

    /// The user's own choice (`contextID` nil means "unassigned"); reanalysis never changes it.
    public func setUserChoice(imageID: String, contextID: String?, at date: Date) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO image_context (image_id, context_id, source, score, matched_json, runner_up_json, decided_at)
                VALUES (?, ?, 'user', 0, '[]', NULL, ?)
                ON CONFLICT(image_id) DO UPDATE SET context_id = excluded.context_id, source = 'user', score = 0, matched_json = '[]',
                    runner_up_json = NULL, decided_at = excluded.decided_at
                """, arguments: [imageID, contextID, date])
        }
    }

    public func decision(imageID: String) throws -> ContextDecision? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM image_context WHERE image_id = ?", arguments: [imageID]),
                  let source = ContextDecision.Source(rawValue: row["source"]) else { return nil }
            let decoder = JSONDecoder()
            let matched = (row["matched_json"] as String?).flatMap { try? decoder.decode([MatchedHint].self, from: Data($0.utf8)) } ?? []
            let runnerUp = (row["runner_up_json"] as String?).flatMap { try? decoder.decode(RunnerUp.self, from: Data($0.utf8)) }
            return ContextDecision(contextID: row["context_id"], source: source, score: row["score"], matched: matched, runnerUp: runnerUp)
        }
    }
}
