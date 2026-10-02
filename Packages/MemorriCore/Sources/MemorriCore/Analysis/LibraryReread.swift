import Foundation
import GRDB
import os

/// Queues the one-off re-read of the library after an update that changes how pictures are read (spec 011, FR-011a): every stored capture whose
/// picture is still kept gets a `reread` job at a priority below new captures, so it never delays one. The stored text is reused and every model
/// step is made again; what the user edited, locked, approved or dismissed lives on items and is not touched (spec 005 and 006).
public struct LibraryReread: Sendable {
    /// The setting that remembers which re-read the library was last queued for.
    public static let settingKey = "library-reread-version"
    /// Raised whenever a change of the prompts or of how windows are read should read the library again; 1 is `windows-v1`.
    public static let currentVersion = 1
    /// Below the 0 of new captures and of what the user asks for.
    public static let priority = 1
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "reread")

    private let database: StorageDatabase
    private let settings: any SettingsStore
    private let paths: AppPaths

    public init(database: StorageDatabase, settings: any SettingsStore, paths: AppPaths) {
        self.database = database; self.settings = settings; self.paths = paths
    }

    /// Queues the jobs when the library has not been queued for the current version yet, newest capture first. Returns how many jobs were queued;
    /// 0 once it is done (and when there is nothing to read). Pictures that are gone, pictures with no analysis and pictures that already have a
    /// waiting or running job are left out.
    @discardableResult
    public func enqueueIfNeeded(now: Date) throws -> Int {
        guard (settings.int(forKey: Self.settingKey) ?? 0) < Self.currentVersion else { return 0 }
        let candidates: [(id: String, full: String, model: String)] = try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT i.id, i.full_path, i.model_path FROM capture_images i JOIN capture_events e ON e.id = i.event_id
                WHERE i.missing = 0
                  AND EXISTS (SELECT 1 FROM image_analysis a WHERE a.image_id = i.id)
                  AND NOT EXISTS (SELECT 1 FROM analysis_jobs j WHERE j.image_id = i.id AND j.kind IN ('analyse', 'analyse-force', 'reread')
                                  AND j.state IN ('waiting', 'running'))
                ORDER BY e.captured_at DESC, i.display_id ASC, i.id ASC
                """).map { ($0["id"], $0["full_path"], $0["model_path"]) }
        }
        let kept = candidates.filter { candidate in
            [candidate.full, candidate.model].allSatisfy { FileManager.default.fileExists(atPath: paths.root.appendingPathComponent($0).path) }
        }
        try database.pool.write { db in
            for (offset, candidate) in kept.enumerated() {
                // Jobs are created together; the store orders equal times by id, so nudge each one to keep the newest first.
                try AnalysisJobRecord(kind: ImageAnalysisJobRunner.rereadKind, imageId: candidate.id, createdAt: now.addingTimeInterval(Double(offset) * 0.001),
                                      priority: Self.priority).insert(db)
            }
        }
        settings.setInt(Self.currentVersion, forKey: Self.settingKey)
        Self.logger.info("enqueued reread=\(kept.count) skipped=\(candidates.count - kept.count)")
        return kept.count
    }
}
