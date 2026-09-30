import Foundation
import GRDB

/// The stored analysis of one picture (its `image_analysis` row).
public struct StoredAnalysis: Sendable, Equatable {
    public let imageID: String
    public let kind: ScreenKind
    public let kindConfidence: Double
    public let classifyVersion: String
    public let promptVersion: String
    public let schemaVersion: String
    public let model: String
    public let pictureLongEdge: Int
    public let timezone: String
    public let timezoneSource: String
    public let findingCount: Int
    public let lineCapApplied: Bool
    public let discarded: [CitationCheck.Discard]
    public let extractRunID: String?
    public let analysedAt: Date
}

/// Saves what an analysis found, one picture at a time. The analysis row, the findings, the tags and the context are
/// written in one transaction, replacing the earlier analysis of the picture; a user's choice of context stays.
public struct AnalysisResultStore: Sendable {
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

    public func save(_ result: AnalysisResult, imageID: String, runID: String?, at date: Date) throws {
        let kind = result.classification.kind
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM findings WHERE image_id = ?", arguments: [imageID])
            try db.execute(sql: "DELETE FROM capture_tags WHERE image_id = ?", arguments: [imageID])
            try db.execute(sql: """
                INSERT OR REPLACE INTO image_analysis (image_id, screen_kind, kind_confidence, classify_version, prompt_version, schema_version,
                    model, picture_long_edge, timezone, timezone_source, finding_count, line_cap_applied, discarded_json, extract_run_id, analysed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [imageID, kind.rawValue, result.classification.confidence, ExtractionPrompts.classifyVersion,
                                 ExtractionPrompts.version(for: kind), ExtractionSchemas.schemaVersion(for: kind), result.model,
                                 result.pictureLongEdge, result.timezone.identifier, result.timezoneSource, result.findings.count,
                                 result.lineCapApplied ? 1 : 0, Self.encode(result.discards), runID, date])
            for tag in result.tags {
                try db.execute(sql: "INSERT OR REPLACE INTO capture_tags (image_id, key, value, confidence, source) VALUES (?, ?, ?, ?, ?)",
                               arguments: [imageID, tag.key, tag.value, tag.confidence, tag.source])
            }
            for f in result.findings {
                try db.execute(sql: """
                    INSERT INTO findings (id, image_id, run_id, kind, title, all_day, start_at, end_at, due_at, remind_at, timezone, people_json,
                        place, notes, cited_lines_json, confidence, provenance_json, unresolved_json, tags_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [f.id, imageID, runID, f.kind.rawValue, f.title, f.allDay ? 1 : 0, f.start, f.end, f.due, f.remind, f.timezone,
                                     Self.encode(f.people), f.place, f.notes, Self.encode(f.citedLines), f.confidence, Self.encode(f.provenance),
                                     Self.encode(f.unresolved), Self.encode(f.tags), date])
            }
            let decision = result.decision
            try db.execute(sql: """
                INSERT INTO image_context (image_id, context_id, source, score, matched_json, runner_up_json, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(image_id) DO UPDATE SET context_id = excluded.context_id, source = excluded.source, score = excluded.score,
                    matched_json = excluded.matched_json, runner_up_json = excluded.runner_up_json, decided_at = excluded.decided_at
                WHERE image_context.source != 'user'
                """, arguments: [imageID, decision.contextID, decision.source.rawValue, decision.score, Self.encode(decision.matched),
                                 decision.runnerUp.map { Self.encode($0) }, date])
        }
    }

    public func analysis(imageID: String) throws -> StoredAnalysis? {
        try database.pool.read { try Self.analysis($0, imageID: imageID) }
    }

    public func findings(imageID: String) throws -> [Finding] {
        try database.pool.read { try Self.findings($0, imageID: imageID) }
    }

    public func tags(imageID: String) throws -> [CaptureTag] {
        try database.pool.read { try Self.tags($0, imageID: imageID) }
    }

    // The same reads inside an open connection, for callers that already hold one (GRDB does not nest).
    static func analysis(_ db: Database, imageID: String) throws -> StoredAnalysis? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM image_analysis WHERE image_id = ?", arguments: [imageID]),
              let kind = ScreenKind(rawValue: row["screen_kind"]) else { return nil }
        return StoredAnalysis(imageID: imageID, kind: kind, kindConfidence: row["kind_confidence"], classifyVersion: row["classify_version"],
                              promptVersion: row["prompt_version"], schemaVersion: row["schema_version"], model: row["model"],
                              pictureLongEdge: row["picture_long_edge"], timezone: row["timezone"], timezoneSource: row["timezone_source"],
                              findingCount: row["finding_count"], lineCapApplied: (row["line_cap_applied"] as Int) != 0,
                              discarded: Self.decode(row["discarded_json"], as: [CitationCheck.Discard].self) ?? [],
                              extractRunID: row["extract_run_id"], analysedAt: row["analysed_at"])
    }

    static func findings(_ db: Database, imageID: String) throws -> [Finding] {
        try Row.fetchAll(db, sql: "SELECT * FROM findings WHERE image_id = ? ORDER BY start_at, due_at, created_at, rowid", arguments: [imageID]).compactMap { row in
            guard let kind = FindingKind(rawValue: row["kind"]) else { return nil }
            return Finding(id: row["id"], kind: kind, title: row["title"], allDay: (row["all_day"] as Int) != 0, start: row["start_at"],
                           end: row["end_at"], due: row["due_at"], remind: row["remind_at"], timezone: row["timezone"],
                           people: Self.decode(row["people_json"], as: [String].self) ?? [], place: row["place"], notes: row["notes"],
                           citedLines: Self.decode(row["cited_lines_json"], as: [Int].self) ?? [], confidence: row["confidence"],
                           provenance: Self.decode(row["provenance_json"], as: [String: FieldProvenance].self) ?? [:],
                           unresolved: Self.decode(row["unresolved_json"], as: [String: String].self) ?? [:],
                           tags: Self.decode(row["tags_json"], as: [CaptureTag].self) ?? [])
        }
    }

    static func tags(_ db: Database, imageID: String) throws -> [CaptureTag] {
        try Row.fetchAll(db, sql: "SELECT * FROM capture_tags WHERE image_id = ? ORDER BY key, value", arguments: [imageID]).map {
            CaptureTag(key: $0["key"], value: $0["value"], confidence: $0["confidence"], source: $0["source"])
        }
    }

    /// Pictures that have no analysis and no waiting or running job, oldest capture first.
    public func unanalysedImageIDs() throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT i.id FROM capture_images i JOIN capture_events e ON e.id = i.event_id
                WHERE i.missing = 0
                  AND NOT EXISTS (SELECT 1 FROM image_analysis a WHERE a.image_id = i.id)
                  AND NOT EXISTS (SELECT 1 FROM analysis_jobs j WHERE j.image_id = i.id AND j.kind IN ('analyse', 'analyse-force')
                                  AND j.state IN ('waiting', 'running'))
                ORDER BY e.captured_at ASC, i.display_id ASC, i.id ASC
                """)
        }
    }
}
