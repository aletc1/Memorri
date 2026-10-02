import Foundation
import os

/// Deletes captures (record and pictures together) older than a number of days, or all of them.
/// Every kind of deletion goes through here: rows first in one transaction, then the folders, so a
/// crash in between leaves only folders that the start-up sweep removes. Items found in the captures are kept
/// (FR-023, ADR 0010), except those left with no sighting that the user never touched (spec 005, ADR 0020).
public struct CleanupService: Sendable {
    public struct Preview: Sendable, Equatable {
        public let captureCount: Int
        public let bytes: Int64

        public init(captureCount: Int, bytes: Int64) {
            self.captureCount = captureCount
            self.bytes = bytes
        }
    }

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    private let paths: AppPaths
    private let store: CaptureStore
    private let files: CaptureFileStore
    private let time: any TimeSource

    public init(paths: AppPaths, store: CaptureStore, files: CaptureFileStore, time: any TimeSource = SystemTimeSource()) {
        self.paths = paths
        self.store = store
        self.files = files
        self.time = time
    }

    /// What `delete(olderThanDays:)` would remove now. `nil` means all captures.
    public func preview(olderThanDays days: Int?, now: Date? = nil) throws -> Preview {
        let events = try events(olderThanDays: days, now: now)
        let bytes = events.reduce(Int64(0)) { total, event in
            total + StorageStats.bytes(under: files.captureDirectory(eventID: event.id, capturedAt: event.capturedAt))
        }
        // "Delete everything" also removes the evidence cut-outs, which otherwise outlive their captures (spec 006).
        return Preview(captureCount: events.count, bytes: days == nil ? bytes + StorageStats.bytes(under: paths.evidence) : bytes)
    }

    /// Returns how many captures were deleted. A capture in progress is not in the database yet,
    /// so it cannot be selected.
    @discardableResult
    public func delete(olderThanDays days: Int?, now: Date? = nil) throws -> Int {
        let events = try events(olderThanDays: days, now: now)
        if days == nil {
            do { try EvidenceFiles.removeAll(paths: paths, database: store.database) }
            catch { Self.logger.error("cleanup evidence removal failed: \(error.localizedDescription, privacy: .public)") }
        }
        guard !events.isEmpty else { return 0 }
        try store.deleteEvents(ids: events.map(\.id))
        // Items lose their sightings with the captures; the sweep rebuilds them and drops the empty ones nobody touched.
        do {
            let itemsRemoved = try ItemStore(database: store.database).sweep(at: time.now())
            Self.logger.notice("cleanup items removed=\(itemsRemoved)")
            // Items the sweep removed take their evidence rows with them; their files go now.
            if itemsRemoved > 0 { _ = try? EvidenceFiles.removeOrphans(paths: paths, database: store.database) }
        } catch {
            Self.logger.error("cleanup item sweep failed: \(error.localizedDescription, privacy: .public)")
        }

        for event in events { files.removeCaptureDirectory(eventID: event.id, capturedAt: event.capturedAt) }
        Self.logger.notice("cleanup removed=\(events.count)")
        return events.count
    }

    private func events(olderThanDays days: Int?, now: Date?) throws -> [CaptureEventRecord] {
        guard let days else { return try store.events(olderThan: nil) }
        return try store.events(olderThan: (now ?? time.now()).addingTimeInterval(-Double(days) * 86_400))
    }
}
