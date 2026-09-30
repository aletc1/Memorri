import Foundation
import os

/// Something the user must be told once at start-up.
public enum StartupNotice: Sendable, Equatable {
    /// The old database was renamed to this file name in the Memorri folder (FR-019).
    case damagedDatabaseSetAside(fileName: String)
}

/// What the app gets from a start-up.
public struct StorageContext: Sendable {
    public let paths: AppPaths
    /// `nil` when the database cannot be used (see `capturingDisabledReason`).
    public let store: CaptureStore?
    public let files: CaptureFileStore
    public let notice: StartupNotice?
    /// Set when the database came from a newer version: capturing is off until the app is updated (FR-013).
    public let capturingDisabledReason: String?
    public let reconcile: ReconcileReport?
}

public enum StorageBootstrap {
    public static let newerVersionReason = "database from a newer version"

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    /// Prepares the folders, opens the database and reconciles leftovers (FR-014).
    public static func start(paths: AppPaths) throws -> StorageContext {
        try paths.prepare()
        let files = CaptureFileStore(paths: paths)
        switch try StorageDatabase.open(paths: paths) {
        case .refusedNewerVersion:
            logger.notice("database from a newer version left untouched")
            return StorageContext(paths: paths, store: nil, files: files, notice: nil,
                                  capturingDisabledReason: newerVersionReason, reconcile: nil)
        case .opened(let database):
            return try finish(paths: paths, files: files, database: database, notice: nil)
        case .openedAfterSettingAside(let database, let damaged):
            logger.notice("damaged database set aside as \(damaged.lastPathComponent, privacy: .public)")
            return try finish(paths: paths, files: files, database: database,
                              notice: .damagedDatabaseSetAside(fileName: damaged.lastPathComponent))
        }
    }

    private static func finish(paths: AppPaths, files: CaptureFileStore, database: StorageDatabase,
                               notice: StartupNotice?) throws -> StorageContext {
        let store = CaptureStore(database: database)
        let report = try files.reconcile(with: store)
        logger.notice("reconcile staging=\(report.stagingRemoved) orphans=\(report.orphansRemoved) missing=\(report.markedMissing)")
        return StorageContext(paths: paths, store: store, files: files, notice: notice,
                              capturingDisabledReason: nil, reconcile: report)
    }
}
