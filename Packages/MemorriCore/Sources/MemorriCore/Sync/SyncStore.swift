import Foundation
import GRDB

/// One run of sync, kept for the settings tab (the last 20).
public struct SyncRunRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let finishedAt: Date
    public let preview: Bool
    public var created = 0, updated = 0, removed = 0, adopted = 0, skipped = 0, failed = 0
    /// One line per failure or notable event, never an item's content.
    public var detail: [String] = []

    public init(id: String = UUID().uuidString, startedAt: Date, finishedAt: Date, preview: Bool) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt; self.preview = preview
    }
}

/// `sync_links`, `sync_runs` and the user's choices (spec 009).
public struct SyncStore: Sendable {
    public static let enabledKey = "sync.enabled"
    public static let calendarKey = "sync.calendarID"
    public static let listKey = "sync.listID"
    public static let confirmedKey = "sync.firstSyncConfirmed"
    public static let keptRuns = 20

    let database: StorageDatabase
    let settings: any SettingsStore

    public init(database: StorageDatabase, settings: any SettingsStore) { self.database = database; self.settings = settings }

    // MARK: Choices

    public var enabled: Bool { settings.bool(forKey: Self.enabledKey, default: false) }
    public func setEnabled(_ value: Bool) { settings.setBool(value, forKey: Self.enabledKey) }
    public var calendarID: String? { settings.string(forKey: Self.calendarKey).flatMap { $0.isEmpty ? nil : $0 } }
    public var listID: String? { settings.string(forKey: Self.listKey).flatMap { $0.isEmpty ? nil : $0 } }
    public func setCalendarID(_ id: String?) { settings.setString(id ?? "", forKey: Self.calendarKey) }
    public func setListID(_ id: String?) { settings.setString(id ?? "", forKey: Self.listKey) }
    /// The first sync after switching on waits for the user to have seen a preview and pressed `Sync now` (FR-012).
    public var firstSyncConfirmed: Bool { settings.bool(forKey: Self.confirmedKey, default: false) }
    public func setFirstSyncConfirmed(_ value: Bool) { settings.setBool(value, forKey: Self.confirmedKey) }

    public func syncSettings(now: Date) -> SyncSettings { SyncSettings(calendarID: calendarID, listID: listID, now: now) }

    // MARK: Links

    public func links() throws -> [String: SyncLink] {
        try database.pool.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT * FROM sync_links").compactMap { row in Self.link(row) }.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func link(itemID: String) throws -> SyncLink? { try database.pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM sync_links WHERE item_id = ?", arguments: [itemID]).flatMap(Self.link) } }

    public func isLinked(ekID: String) -> Bool {
        (try? database.pool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM sync_links WHERE ek_id = ?)", arguments: [ekID]) }) ?? false
    }

    public func save(_ link: SyncLink, at date: Date) throws {
        let fields = Self.encode(link.fields)
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_links (item_id, kind, ek_id, container_id, hash, hash_version, fields_json, state, failure, synced_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET kind = excluded.kind, ek_id = excluded.ek_id, container_id = excluded.container_id, hash = excluded.hash,
                    hash_version = excluded.hash_version, fields_json = excluded.fields_json, state = excluded.state, failure = excluded.failure,
                    synced_at = excluded.synced_at
                """, arguments: [link.itemID, link.kind.rawValue, link.ekID, link.containerID, link.hash, link.hashVersion, fields, link.state.rawValue,
                                 link.failure, link.syncedAt, date])
        }
    }

    public func deleteLink(itemID: String) throws { try database.pool.write { try $0.execute(sql: "DELETE FROM sync_links WHERE item_id = ?", arguments: [itemID]) } }

    /// Forgets an entry the user deleted so the item can be written again (`Sync again`).
    public func syncAgain(itemID: String) throws { try deleteLink(itemID: itemID) }

    static func link(_ row: Row) -> SyncLink? {
        guard let kind = SyncEntryKind(rawValue: row["kind"]), let state = SyncLinkState(rawValue: row["state"]),
              let fields = (row["fields_json"] as String?).flatMap({ try? decoder.decode(RenderedEntry.self, from: Data($0.utf8)) }) else { return nil }
        return SyncLink(itemID: row["item_id"], kind: kind, ekID: row["ek_id"], containerID: row["container_id"], hash: row["hash"], hashVersion: row["hash_version"],
                        fields: fields, state: state, failure: row["failure"], syncedAt: row["synced_at"])
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private static func encode(_ entry: RenderedEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Runs

    public func record(_ run: SyncRunRecord) throws {
        let detail = (try? JSONEncoder().encode(run.detail)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_runs (id, started_at, finished_at, preview, created, updated, removed, adopted, skipped, failed, detail_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [run.id, run.startedAt, run.finishedAt, run.preview ? 1 : 0, run.created, run.updated, run.removed, run.adopted, run.skipped, run.failed, detail])
            try db.execute(sql: "DELETE FROM sync_runs WHERE id NOT IN (SELECT id FROM sync_runs ORDER BY started_at DESC, rowid DESC LIMIT ?)", arguments: [Self.keptRuns])
        }
    }

    public func runs(limit: Int = keptRuns) throws -> [SyncRunRecord] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_runs ORDER BY started_at DESC, rowid DESC LIMIT ?", arguments: [limit]).map { row in
                var run = SyncRunRecord(id: row["id"], startedAt: row["started_at"], finishedAt: row["finished_at"], preview: (row["preview"] as Int) != 0)
                run.created = row["created"]; run.updated = row["updated"]; run.removed = row["removed"]; run.adopted = row["adopted"]
                run.skipped = row["skipped"]; run.failed = row["failed"]
                run.detail = (row["detail_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                return run
            }
        }
    }
}
