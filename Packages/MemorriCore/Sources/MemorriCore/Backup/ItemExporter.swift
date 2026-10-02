import Foundation
import GRDB

/// One item as it is written to the export file: its fields, review state, the user's locked fields, aliases, sightings with their text and sync state.
public struct ItemExportFile: Codable, Equatable, Sendable {
    public struct Sighting: Codable, Equatable, Sendable {
        public let title: String
        public let capturedAt: Date
        public let windowApp: String?
        public let windowTitle: String?
        public let lines: [String]
    }
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let status: String
        public let mergedInto: String?
        public let context: String?
        public let title: String
        public let allDay: Bool
        public let start: Date?
        public let end: Date?
        public let due: Date?
        public let remind: Date?
        public let timezone: String
        public let people: [String]
        public let place: String?
        public let notes: String?
        public let confidence: Double
        public let needsReview: Bool
        public let reviewReasons: [String]
        public let approvedAt: Date?
        public let firstSeen: Date
        public let lastSeen: Date
        /// The fields the user set by hand.
        public let lockedFields: [String]
        public let aliases: [String]
        public let sightings: [Sighting]
        /// `synced`, `completed`, `removed_by_user`, `removed` or `failed`; nil when never written to Calendar or Reminders.
        public let syncState: String?
    }

    public let format: Int
    public let exportedAt: Date
    public let items: [Entry]
}

extension JSONDecoder {
    /// Reads an export file back.
    public static var exportDecoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

/// Writes every item (dismissed and merged ones too) to one JSON file, with no pictures (spec 010 FR-016).
public struct ItemExporter: Sendable {
    public static let format = 1

    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    /// Returns how many items were written. The file appears whole or not at all.
    @discardableResult
    public func export(to url: URL, exportedAt: Date = Date()) throws -> Int {
        let entries = try database.pool.read { db -> [ItemExportFile.Entry] in
            let contexts = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name FROM contexts").map { ($0["id"] as String, $0["name"] as String) })
            return try Row.fetchAll(db, sql: "SELECT * FROM items ORDER BY first_seen, id").compactMap { row -> ItemExportFile.Entry? in
                guard let item = ItemStore.item(from: row) else { return nil }
                let locks = try String.fetchAll(db, sql: "SELECT field FROM field_locks WHERE item_id = ? ORDER BY field", arguments: [item.id])
                let aliases = try String.fetchAll(db, sql: "SELECT title FROM item_aliases WHERE item_id = ? ORDER BY title", arguments: [item.id])
                let sightings = try Row.fetchAll(db, sql: """
                    SELECT image_id, captured_at, title, cited_lines_json, window_app, window_title FROM sightings WHERE item_id = ? ORDER BY captured_at, id
                    """, arguments: [item.id]).map { sighting -> ItemExportFile.Sighting in
                    let cited = (sighting["cited_lines_json"] as String?).flatMap { try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) } ?? []
                    let lines = try cited.compactMap { n in
                        try String.fetchOne(db, sql: "SELECT text FROM ocr_lines WHERE image_id = ? AND n = ?", arguments: [sighting["image_id"] as String, n])
                    }
                    return ItemExportFile.Sighting(title: sighting["title"], capturedAt: sighting["captured_at"], windowApp: sighting["window_app"],
                                                   windowTitle: sighting["window_title"], lines: lines)
                }
                let sync = try String.fetchOne(db, sql: "SELECT state FROM sync_links WHERE item_id = ?", arguments: [item.id])
                return ItemExportFile.Entry(id: item.id, kind: item.kind.rawValue, status: item.status.rawValue, mergedInto: item.mergedInto,
                                            context: item.contextID.flatMap { contexts[$0] }, title: item.title, allDay: item.allDay, start: item.start,
                                            end: item.end, due: item.due, remind: item.remind, timezone: item.timezone, people: item.people,
                                            place: item.place, notes: item.notes, confidence: item.confidence, needsReview: item.needsReview,
                                            reviewReasons: item.reviewReasons.map(\.rawValue), approvedAt: item.approvedAt, firstSeen: item.firstSeen,
                                            lastSeen: item.lastSeen, lockedFields: locks, aliases: aliases, sightings: sightings, syncState: sync)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ItemExportFile(format: Self.format, exportedAt: exportedAt, items: entries))
        try data.write(to: url, options: .atomic)
        return entries.count
    }
}
