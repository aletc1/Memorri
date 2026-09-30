import Foundation

/// What a start-up reconcile did (logged as `reconcile staging=… orphans=… missing=…`).
public struct ReconcileReport: Sendable, Equatable {
    public let stagingRemoved: Int
    public let orphansRemoved: Int
    public let markedMissing: Int
}

/// The picture files: staging, atomic commit, deletion and the start-up sweep (ADR 0009).
public struct CaptureFileStore: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func makeStagingDirectory() throws -> URL {
        let url = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Renames the staging directory into `captures/<yyyy-MM>/<eventID>/` (atomic on one volume).
    public func commit(staging: URL, eventID: String, capturedAt: Date) throws -> URL {
        let final = captureDirectory(eventID: eventID, capturedAt: capturedAt)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: staging, to: final)
        return final
    }

    public func discard(staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    public func removeCaptureDirectory(eventID: String, capturedAt: Date) {
        try? FileManager.default.removeItem(at: captureDirectory(eventID: eventID, capturedAt: capturedAt))
    }

    /// Start-up sweep (FR-014): empties `staging/`, removes capture directories without a record,
    /// and marks records whose picture file is gone.
    @discardableResult
    public func reconcile(with store: CaptureStore) throws -> ReconcileReport {
        let manager = FileManager.default

        var stagingRemoved = 0
        for url in (try? manager.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: url)
            stagingRemoved += 1
        }

        let knownEvents = Set(try store.events(olderThan: nil).map(\.id))
        var orphansRemoved = 0
        for month in (try? manager.contentsOfDirectory(at: paths.captures, includingPropertiesForKeys: nil)) ?? [] {
            for event in (try? manager.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
            where !knownEvents.contains(event.lastPathComponent) {
                try? manager.removeItem(at: event)
                orphansRemoved += 1
            }
            if ((try? manager.contentsOfDirectory(atPath: month.path)) ?? []).isEmpty {
                try? manager.removeItem(at: month)
            }
        }

        var markedMissing = 0
        for image in try store.allImages() where !image.missing {
            let full = paths.root.appendingPathComponent(image.fullPath).path
            let model = paths.root.appendingPathComponent(image.modelPath).path
            if !manager.fileExists(atPath: full) || !manager.fileExists(atPath: model) {
                try store.markMissing(imageID: image.id)
                markedMissing += 1
            }
        }
        return ReconcileReport(stagingRemoved: stagingRemoved, orphansRemoved: orphansRemoved,
                               markedMissing: markedMissing)
    }

    private func captureDirectory(eventID: String, capturedAt: Date) -> URL {
        paths.captures
            .appendingPathComponent(Self.monthFolder(for: capturedAt), isDirectory: true)
            .appendingPathComponent(eventID, isDirectory: true)
    }

    static func monthFolder(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }
}
