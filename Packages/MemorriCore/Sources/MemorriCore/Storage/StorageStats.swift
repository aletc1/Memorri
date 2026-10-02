import Foundation

/// What the Storage section of Settings shows.
public struct StorageSummary: Sendable, Equatable {
    public let captureCount: Int
    public let pictureBytes: Int64
    public let databaseBytes: Int64
    /// The cut-outs that prove items; they are kept after their captures are deleted (spec 006).
    public let evidenceBytes: Int64
    /// The libraries a restore replaced, and a restore waiting for the next start (spec 010).
    public let safetyCopyBytes: Int64
}

/// Reads the real figures: the count from the database, the space from the files themselves
/// (SC-006), so the numbers stay true even if files change outside the app.
public struct StorageStats: Sendable {
    private let paths: AppPaths
    private let store: CaptureStore

    public init(paths: AppPaths, store: CaptureStore) {
        self.paths = paths
        self.store = store
    }

    public func summary() throws -> StorageSummary {
        StorageSummary(captureCount: try store.count(),
                       pictureBytes: Self.bytes(under: paths.captures),
                       databaseBytes: ["", "-wal", "-shm"].reduce(0) { $0 + Self.size(ofFileAt: paths.database.path + $1) },
                       evidenceBytes: Self.bytes(under: paths.evidence),
                       safetyCopyBytes: Self.bytes(under: paths.safetyCopies) + Self.bytes(under: paths.restorePending))
    }

    static func bytes(under directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func size(ofFileAt path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
