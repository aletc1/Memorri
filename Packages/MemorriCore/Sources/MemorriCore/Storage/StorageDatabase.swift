import Foundation
import GRDB

/// The SQLite database (GRDB `DatabasePool`, WAL, foreign keys on).
public final class StorageDatabase: Sendable {
    public enum OpenResult: Sendable {
        case opened(StorageDatabase)
        /// The old file (and its -wal/-shm) was renamed, never deleted, and a new database created (FR-019).
        case openedAfterSettingAside(StorageDatabase, damagedFile: URL)
        /// The file has migrations this version does not know; it was not modified (FR-013).
        case refusedNewerVersion
    }

    let pool: DatabasePool

    init(pool: DatabasePool) {
        self.pool = pool
    }

    /// Expects `paths.prepare()` to have been called.
    public static func open(paths: AppPaths) throws -> OpenResult {
        do {
            return try attempt(paths: paths, damaged: nil)
        } catch let error as DatabaseError where error.isDamageError {
            let damaged = try setAside(paths: paths)
            return try attempt(paths: paths, damaged: damaged)
        }
    }

    private static func attempt(paths: AppPaths, damaged: URL?) throws -> OpenResult {
        let pool = try DatabasePool(path: paths.database.path)
        let migrator = Migrations.make()
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) {
            try pool.close()
            return .refusedNewerVersion
        }
        try migrator.migrate(pool)
        let database = StorageDatabase(pool: pool)
        if let damaged { return .openedAfterSettingAside(database, damagedFile: damaged) }
        return .opened(database)
    }

    private static func setAside(paths: AppPaths) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let manager = FileManager.default
        var target = paths.root.appendingPathComponent("memorri.sqlite.damaged-\(stamp)")
        var counter = 1
        while manager.fileExists(atPath: target.path) {
            target = paths.root.appendingPathComponent("memorri.sqlite.damaged-\(stamp)-\(counter)")
            counter += 1
        }
        try manager.moveItem(at: paths.database, to: target)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: paths.database.path + suffix)
            if manager.fileExists(atPath: side.path) {
                try manager.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }
}

private extension DatabaseError {
    var isDamageError: Bool {
        resultCode == .SQLITE_NOTADB || resultCode == .SQLITE_CORRUPT
    }
}
