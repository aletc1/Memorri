import Foundation
import GRDB

/// The derived search tables (ADR 0023). Item documents are kept by triggers (migration `v9`); a capture's document is written with its text.
public struct SearchIndex: Sendable {
    /// Replaces the capture's document with its lines, in reading order, one per line. A capture with no text has no document.
    static func writeCapture(_ db: Database, imageID: String, lines: [RecognisedLine]) throws {
        try db.execute(sql: "DELETE FROM search_captures WHERE image_id = ?", arguments: [imageID])
        let body = lines.sorted { $0.n < $1.n }.map(\.text).joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(sql: "INSERT INTO search_captures (image_id, body) VALUES (?, ?)", arguments: [imageID, body])
    }
}
