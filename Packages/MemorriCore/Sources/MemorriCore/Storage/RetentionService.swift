import Foundation
import os

/// Applies the retention policy to captures, at start and about once a day (FR-017). It only ever
/// removes captures, through `CleanupService`; items found in them are kept (ADR 0010).
public struct RetentionService: Sendable {
    public static let lastRunKey = "memorri.retention.lastRun"
    /// Minimum time between automatic runs.
    public static let interval: TimeInterval = 86_400

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    private let cleanup: CleanupService
    private let settings: StorageSettings
    private let store: any SettingsStore

    public init(cleanup: CleanupService, settings: StorageSettings, store: any SettingsStore) {
        self.cleanup = cleanup
        self.settings = settings
        self.store = store
    }

    /// Removes the captures older than the policy; returns how many went.
    @discardableResult
    public func apply(now: Date) throws -> Int {
        guard case .days(let days) = settings.retention else { return 0 }
        let removed = try cleanup.delete(olderThanDays: days, now: now)
        Self.logger.notice("retention removed=\(removed)")
        return removed
    }

    /// `apply` and remember when it ran; used at start and after the policy changes.
    @discardableResult
    public func runNow(now: Date) throws -> Int {
        let removed = try apply(now: now)
        store.setDate(now, forKey: Self.lastRunKey)
        return removed
    }

    /// `runNow`, unless it already ran in the last 24 hours.
    @discardableResult
    public func runIfDue(now: Date) throws -> Int {
        if let last = store.date(forKey: Self.lastRunKey), now.timeIntervalSince(last) < Self.interval { return 0 }
        return try runNow(now: now)
    }

    /// What switching to `policy` would remove right now (FR-018).
    public func removalPreview(for policy: RetentionPolicy, now: Date) throws -> CleanupService.Preview {
        guard case .days(let days) = policy else { return CleanupService.Preview(captureCount: 0, bytes: 0) }
        return try cleanup.preview(olderThanDays: days, now: now)
    }
}
