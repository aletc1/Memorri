import Foundation
import GRDB

/// Keeps what each window of a picture was (`window_readings`, migration v8). The rows of a picture are replaced as a whole.
public struct WindowReadingStore: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static func decode<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    public func save(imageID: String, readings: [WindowReadingRecord]) throws {
        try database.pool.write { try Self.save($0, imageID: imageID, readings: readings) }
    }

    public func readings(imageID: String) throws -> [WindowReadingRecord] {
        try database.pool.read { try Self.readings($0, imageID: imageID) }
    }

    // The same inside an open connection, for callers that already hold one (GRDB does not nest).
    static func save(_ db: Database, imageID: String, readings: [WindowReadingRecord]) throws {
        try db.execute(sql: "DELETE FROM window_readings WHERE image_id = ?", arguments: [imageID])
        for r in readings {
            try db.execute(sql: """
                INSERT INTO window_readings (image_id, window_key, app_name, title, frame_json, visible_json, visible_share, relevant, kind, confidence,
                    remote, run_id, prompt_version, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [imageID, r.windowKey, r.appName, r.title, encode(r.frame), encode(r.visible), r.visibleShare, r.relevant ? 1 : 0,
                                 r.kind?.rawValue, r.confidence, r.remote ? 1 : 0, r.runID, r.promptVersion, r.createdAt])
        }
    }

    static func readings(_ db: Database, imageID: String) throws -> [WindowReadingRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM window_readings WHERE image_id = ? ORDER BY window_key", arguments: [imageID]).compactMap { row in
            guard let frame = decode(row["frame_json"], as: PixelBox.self) else { return nil }
            return WindowReadingRecord(imageID: imageID, windowKey: row["window_key"], appName: row["app_name"], title: row["title"], frame: frame,
                                       visible: decode(row["visible_json"], as: [PixelBox].self) ?? [], visibleShare: row["visible_share"],
                                       relevant: (row["relevant"] as Int) != 0, kind: (row["kind"] as String?).flatMap(ScreenKind.init(rawValue:)),
                                       confidence: row["confidence"], remote: (row["remote"] as Int) != 0, runID: row["run_id"],
                                       promptVersion: row["prompt_version"], createdAt: row["created_at"])
        }
    }
}
