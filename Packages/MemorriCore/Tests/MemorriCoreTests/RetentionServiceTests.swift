import Foundation
import Testing
@testable import MemorriCore

@Suite struct RetentionServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let settingsStore = FakeSettingsStore()
        let settings: StorageSettings
        let retention: RetentionService

        init() throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            settings = StorageSettings(store: settingsStore)
            let cleanup = CleanupService(paths: context.paths, store: context.store!, files: context.files)
            retention = RetentionService(cleanup: cleanup, settings: settings, store: settingsStore)
        }

        func addCapture(id: String, at date: Date) throws {
            try context.store!.insert(event: makeEventRecord(id: id, at: date), images: [])
            try FileManager.default.createDirectory(
                at: context.files.captureDirectory(eventID: id, capturedAt: date), withIntermediateDirectories: true)
        }
    }

    @Test func applyRemovesCapturesOlderThanThePolicyAndKeepsTheRest() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-8 * day))
        try h.addCapture(id: "new", at: now.addingTimeInterval(-6 * day))
        #expect(h.settings.retention == .days(7))            // the default
        #expect(try h.retention.apply(now: now) == 1)
        #expect(try h.context.store?.events(olderThan: nil).map(\.id) == ["new"])
    }

    @Test func foreverRemovesNothing() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "ancient", at: now.addingTimeInterval(-900 * day))
        #expect(h.settings.setRetention(.forever))
        #expect(try h.retention.apply(now: now) == 0)
        #expect(try h.context.store?.count() == 1)
    }

    @Test func runIfDueRunsWhenNeverRunAndRemembersTheTime() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-8 * day))
        #expect(try h.retention.runIfDue(now: now) == 1)
        #expect(h.settingsStore.date(forKey: "memorri.retention.lastRun") == now)
    }

    @Test func runIfDueSkipsWithin24HoursAndRunsAfter() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        _ = try h.retention.runIfDue(now: now)
        try h.addCapture(id: "old", at: now.addingTimeInterval(-8 * day))
        #expect(try h.retention.runIfDue(now: now.addingTimeInterval(day - 1)) == 0)
        #expect(try h.context.store?.count() == 1)
        #expect(try h.retention.runIfDue(now: now.addingTimeInterval(day)) == 1)
        #expect(h.settingsStore.date(forKey: "memorri.retention.lastRun") == now.addingTimeInterval(day))
    }

    @Test func runNowAppliesEvenWithinTheDailyWindowAndRemembersTheTime() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        _ = try h.retention.runIfDue(now: now)
        try h.addCapture(id: "old", at: now.addingTimeInterval(-8 * day))
        let later = now.addingTimeInterval(60)
        #expect(try h.retention.runNow(now: later) == 1)
        #expect(h.settingsStore.date(forKey: "memorri.retention.lastRun") == later)
    }

    @Test func removalPreviewSaysWhatAShorterPolicyWouldRemove() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "a", at: now.addingTimeInterval(-2 * day))
        try h.addCapture(id: "b", at: now.addingTimeInterval(-5 * day))
        #expect(try h.retention.removalPreview(for: .days(3), now: now).captureCount == 1)
        #expect(try h.retention.removalPreview(for: .days(1), now: now).captureCount == 2)
        #expect(try h.retention.removalPreview(for: .forever, now: now).captureCount == 0)
        #expect(try h.context.store?.count() == 2)           // a preview changes nothing
    }

    @Test func neverTouchesAnythingOutsideCaptures() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-99 * day))
        let crop = h.context.paths.root.appendingPathComponent("evidence/crop.heic")
        try FileManager.default.createDirectory(at: crop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("crop".utf8).write(to: crop)
        _ = try h.retention.apply(now: now)
        #expect(FileManager.default.fileExists(atPath: crop.path))
    }
}
