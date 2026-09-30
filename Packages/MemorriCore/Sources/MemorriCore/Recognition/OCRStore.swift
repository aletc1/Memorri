import Foundation
import GRDB

/// Keeps what was read from each picture. A read is one `ocr_reads` row and its `ocr_lines`, written together, so a picture
/// is either read (even with no lines) or not read at all, and reading twice cannot duplicate lines.
public struct OCRStore: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    /// Replaces any earlier read of the picture.
    public func save(imageID: String, lines: [RecognisedLine], durationMs: Int, recogniser: String, at date: Date) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM ocr_lines WHERE image_id = ?", arguments: [imageID])
            try db.execute(sql: """
                INSERT OR REPLACE INTO ocr_reads (image_id, read_at, line_count, recogniser, duration_ms) VALUES (?, ?, ?, ?, ?)
                """, arguments: [imageID, date, lines.count, recogniser, durationMs])
            for line in lines {
                try db.execute(sql: """
                    INSERT INTO ocr_lines (image_id, n, text, x, y, width, height, confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [imageID, line.n, line.text, line.box.x, line.box.y, line.box.width, line.box.height, line.confidence])
            }
        }
    }

    public func isRead(imageID: String) throws -> Bool {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_reads WHERE image_id = ?", arguments: [imageID]) ?? 0 } > 0
    }

    /// The lines in reading order.
    public func lines(imageID: String) throws -> [RecognisedLine] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ocr_lines WHERE image_id = ? ORDER BY n", arguments: [imageID]).map { row in
                RecognisedLine(n: row["n"], text: row["text"],
                               box: PixelBox(x: row["x"], y: row["y"], width: row["width"], height: row["height"]),
                               confidence: row["confidence"])
            }
        }
    }
}
