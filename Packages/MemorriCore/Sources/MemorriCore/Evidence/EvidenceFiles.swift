import Foundation
import GRDB

/// The files under `evidence/`: which ones to keep, and removing the rest (spec 006, research R3).
public enum EvidenceFiles {
    /// Removes files no evidence row names, and month folders left empty. Returns how many files were removed.
    @discardableResult
    public static func removeOrphans(paths: AppPaths, database: StorageDatabase) throws -> Int {
        let known = Set(try database.pool.read { try String.fetchAll($0, sql: "SELECT file_path FROM evidence WHERE file_path IS NOT NULL") })
        let manager = FileManager.default
        let rootPath = paths.root.standardizedFileURL.path + "/"
        var removed = 0
        for month in (try? manager.contentsOfDirectory(at: paths.evidence, includingPropertiesForKeys: nil)) ?? [] {
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: month.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                if !known.contains(relative(month, rootPath)) { try? manager.removeItem(at: month); removed += 1 }
                continue
            }
            for file in (try? manager.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
            where !known.contains(relative(file, rootPath)) {
                try? manager.removeItem(at: file)
                removed += 1
            }
            if ((try? manager.contentsOfDirectory(atPath: month.path)) ?? []).isEmpty { try? manager.removeItem(at: month) }
        }
        return removed
    }

    /// "Delete everything": every row and every file under `evidence/` (the folder itself stays).
    public static func removeAll(paths: AppPaths, database: StorageDatabase) throws {
        try database.pool.write { try $0.execute(sql: "DELETE FROM evidence") }
        for entry in (try? FileManager.default.contentsOfDirectory(at: paths.evidence, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func relative(_ url: URL, _ rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }
}
