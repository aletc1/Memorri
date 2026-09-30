import Foundation
import GRDB

public enum CaptureState: Sendable, Equatable {
    case waiting
    case analysing
    case analysed
    case failed(String)
    case notAnalysed
}

/// One stored picture as Settings lists it.
public struct RecentCapture: Sendable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Date
    /// How many displays the whole capture had.
    public let displayCount: Int
    public let displayName: String?
    public let state: CaptureState
    public let kind: ScreenKind?
    public let findingCount: Int
    public let findings: [Finding]
    public let contextName: String?
    public let contextChosenByUser: Bool
    public let tags: [CaptureTag]
}

/// Reads what Settings shows about the newest pictures: when, what state, what kind, what was found.
public struct CaptureOverview: Sendable {
    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    /// The newest `limit` pictures, newest capture first; the displays of one capture stay together.
    public func recent(limit: Int = 20) throws -> [RecentCapture] {
        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.id, i.display_name, e.captured_at, e.display_count FROM capture_images i JOIN capture_events e ON e.id = i.event_id
                ORDER BY e.captured_at DESC, i.display_id ASC, i.id ASC LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                let id: String = row["id"]
                let analysis = try AnalysisResultStore.analysis(db, imageID: id)
                let context = try Row.fetchOne(db, sql: """
                    SELECT c.name AS name, ic.source AS source FROM image_context ic LEFT JOIN contexts c ON c.id = ic.context_id WHERE ic.image_id = ?
                    """, arguments: [id])
                return RecentCapture(id: id, capturedAt: row["captured_at"], displayCount: row["display_count"], displayName: row["display_name"],
                                     state: try state(db, imageID: id, analysed: analysis != nil), kind: analysis?.kind,
                                     findingCount: analysis?.findingCount ?? 0, findings: analysis == nil ? [] : try AnalysisResultStore.findings(db, imageID: id),
                                     contextName: context?["name"], contextChosenByUser: (context?["source"] as String?) == "user",
                                     tags: try AnalysisResultStore.tags(db, imageID: id))
            }
        }
    }

    private func state(_ db: Database, imageID: String, analysed: Bool) throws -> CaptureState {
        func count(_ state: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_jobs WHERE image_id = ? AND kind IN ('analyse', 'analyse-force') AND state = ?",
                             arguments: [imageID, state]) ?? 0
        }
        if try count("running") > 0 { return .analysing }
        if try count("waiting") > 0 { return .waiting }
        if analysed { return .analysed }
        let latest = try Row.fetchOne(db, sql: """
            SELECT state, failure_reason FROM analysis_jobs WHERE image_id = ? AND kind IN ('analyse', 'analyse-force')
            ORDER BY created_at DESC, rowid DESC LIMIT 1
            """, arguments: [imageID])
        if let latest, (latest["state"] as String) == "failed" { return .failed(latest["failure_reason"] ?? "unknown reason") }
        return .notAnalysed
    }
}
