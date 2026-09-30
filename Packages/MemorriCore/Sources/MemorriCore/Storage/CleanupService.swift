import Foundation
import os

/// Deletes captures (record and pictures together) older than a number of days, or all of them.
/// Every kind of deletion goes through here: rows first in one transaction, then the folders, so a
/// crash in between leaves only folders that the start-up sweep removes. It touches captures only,
/// never anything derived from them (FR-023, ADR 0010).
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

    private let store: CaptureStore
    private let files: CaptureFileStore
    private let time: any TimeSource

    public init(paths: AppPaths, store: CaptureStore, files: CaptureFileStore, time: any TimeSource = SystemTimeSource()) {
        self.store = store
        self.files = files
        self.time = time
    }

    /// What `delete(olderThanDays:)` would remove now. `nil` means all captures.
    public func preview(olderThanDays days: Int?) throws -> Preview {
        let events = try events(olderThanDays: days)
        let bytes = events.reduce(Int64(0)) { total, event in
            total + StorageStats.bytes(under: files.captureDirectory(eventID: event.id, capturedAt: event.capturedAt))
        }
        return Preview(captureCount: events.count, bytes: bytes)
    }

    /// Returns how many captures were deleted. A capture in progress is not in the database yet,
    /// so it cannot be selected.
    @discardableResult
    public func delete(olderThanDays days: Int?) throws -> Int {
        let events = try events(olderThanDays: days)
        guard !events.isEmpty else { return 0 }
        try store.deleteEvents(ids: events.map(\.id))
        for event in events { files.removeCaptureDirectory(eventID: event.id, capturedAt: event.capturedAt) }
        Self.logger.notice("cleanup removed=\(events.count)")
        return events.count
    }

    private func events(olderThanDays days: Int?) throws -> [CaptureEventRecord] {
        guard let days else { return try store.events(olderThan: nil) }
        return try store.events(olderThan: time.now().addingTimeInterval(-Double(days) * 86_400))
    }
}
