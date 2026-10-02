import Foundation
import GRDB
import os

/// The derived search tables (ADR 0023). Item documents are kept by triggers (migration `v9`); a capture's document is written with its text.
/// This type writes that second kind, and builds both from the stored data when the index is missing, outdated or does not add up.
public struct SearchIndex: Sendable {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "search")

    /// Raise this when a searchable column or the shape of a document changes: the next launch builds the index again.
    public static let version = 1
    /// How many pictures one rebuild step writes, so the database is free for analysis in between.
    static let batchSize = 100

    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    /// Replaces the capture's document with its lines, in reading order, one per line. A capture with no text has no document.
    static func writeCapture(_ db: Database, imageID: String, lines: [RecognisedLine]) throws {
        try db.execute(sql: "DELETE FROM search_captures WHERE image_id = ?", arguments: [imageID])
        let body = lines.sorted { $0.n < $1.n }.map(\.text).joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(sql: "INSERT INTO search_captures (image_id, body) VALUES (?, ?)", arguments: [imageID, body])
    }

    // MARK: State

    private static func storedVersion(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM search_meta WHERE key = 'index_version'")
    }

    /// Items that should have a row (not merged) plus pictures that were read: what a rebuild goes through.
    private static func total(_ db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE status != 'merged'") ?? 0) + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_reads") ?? 0)
    }

    /// `ready` when the index was built by this version of the app (or there is nothing to index); `preparing` while it has to be built.
    public func state() throws -> SearchState {
        try database.pool.read { db in
            if try Self.storedVersion(db) == String(Self.version) { return .ready }
            let total = try Self.total(db)
            return total == 0 ? .ready : .preparing(done: 0, total: total)
        }
    }

    /// True when the version differs or the rows do not add up to the data (a row went missing, or one is left over).
    private static func needsRebuild(_ db: Database) throws -> Bool {
        if try storedVersion(db) != String(version) { return true }
        let itemsExpected = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE status != 'merged'") ?? 0
        let itemRows = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT item_id) FROM search_items") ?? 0
        let itemRowsTotal = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items") ?? 0
        let capturesExpected = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ocr_reads r WHERE EXISTS (SELECT 1 FROM ocr_lines l WHERE l.image_id = r.image_id AND trim(l.text) != '')
            """) ?? 0
        let captureRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_captures") ?? 0
        return itemRows != itemsExpected || itemRowsTotal != itemsExpected || captureRows != capturesExpected
    }

    // MARK: Building

    /// The same document the triggers write, for every item that is not merged.
    private static func insertAllItems(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM search_items")
        try db.execute(sql: """
            INSERT INTO search_items (item_id, title, aliases, notes, place, people)
            SELECT i.id, i.title,
                   COALESCE((SELECT group_concat(a.title, ' ') FROM item_aliases a WHERE a.item_id = i.id AND a.title != i.title), ''),
                   COALESCE(i.notes, ''), COALESCE(i.place, ''),
                   CASE WHEN json_valid(i.people_json) THEN COALESCE((SELECT group_concat(value, ' ') FROM json_each(i.people_json)), '') ELSE '' END
            FROM items i WHERE i.status != 'merged'
            """)
    }

    private static func lines(_ db: Database, imageID: String) throws -> [RecognisedLine] {
        try Row.fetchAll(db, sql: "SELECT n, text, x, y, width, height, confidence FROM ocr_lines WHERE image_id = ? ORDER BY n", arguments: [imageID]).map { row in
            RecognisedLine(n: row["n"], text: row["text"], box: PixelBox(x: row["x"], y: row["y"], width: row["width"], height: row["height"]), confidence: row["confidence"])
        }
    }

    private static func setVersion(_ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO search_meta (key, value) VALUES ('index_version', ?)", arguments: [String(version)])
    }

    /// Builds everything in one transaction (tests, repair).
    public func rebuild() throws {
        try database.pool.write { db in
            try Self.insertAllItems(db)
            try db.execute(sql: "DELETE FROM search_captures")
            for imageID in try String.fetchAll(db, sql: "SELECT image_id FROM ocr_reads ORDER BY image_id") {
                try Self.writeCapture(db, imageID: imageID, lines: try Self.lines(db, imageID: imageID))
            }
            try Self.setVersion(db)
        }
    }

    /// Does nothing when the index is current and adds up. Otherwise builds it: the items in one step, then the pictures in batches, reporting
    /// progress. Writes made meanwhile are kept (the triggers and `OCRStore` go on working, and each batch writes whole documents again).
    public func prepare(progress: @Sendable (SearchState) -> Void) async throws {
        guard try await database.pool.read({ try Self.needsRebuild($0) }) else { return }
        let started = ContinuousClock.now
        let total = try await database.pool.read { try Self.total($0) }
        progress(.preparing(done: 0, total: total))
        let itemCount = try await database.pool.write { db -> Int in
            try Self.insertAllItems(db)
            try db.execute(sql: "DELETE FROM search_captures")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items") ?? 0
        }
        progress(.preparing(done: itemCount, total: total))
        let pictures = try await database.pool.read { try String.fetchAll($0, sql: "SELECT image_id FROM ocr_reads ORDER BY image_id") }
        var done = itemCount
        for start in stride(from: 0, to: pictures.count, by: Self.batchSize) {
            let batch = Array(pictures[start..<min(start + Self.batchSize, pictures.count)])
            try await database.pool.write { db in
                for imageID in batch { try Self.writeCapture(db, imageID: imageID, lines: try Self.lines(db, imageID: imageID)) }
            }
            done += batch.count
            progress(.preparing(done: done, total: max(total, done)))
        }
        try await database.pool.write { try Self.setVersion($0) }
        progress(.ready)
        let elapsed = started.duration(to: .now).components
        Self.logger.info("search index prepare done=\(done) total=\(total) ms=\(Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))")
    }
}
