import Foundation
import GRDB

/// Whether the app's own queue is in the middle of a model call. `memorri-eval` refuses to run then, because two
/// callers would share one model and skew both timings (spec 004, clarification 2).
public enum BusyCheck {
    /// Opens the database read-only. A missing, unreadable or damaged file, or one without the jobs table, is not busy.
    public static func isBusy(databaseAt url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_jobs WHERE state = 'running'") ?? 0
            } > 0
        } catch {
            return false
        }
    }

    public static func isBusy(paths: AppPaths) -> Bool {
        isBusy(databaseAt: paths.database)
    }
}
