import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct CleanupServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let cleanup: CleanupService
        let time: FakeTimeSource

        init(now: Date) throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            time = FakeTimeSource(now.timeIntervalSinceReferenceDate)
            cleanup = CleanupService(paths: context.paths, store: context.store!, files: context.files, time: time)
        }

        /// A capture whose record says `ageDays` old (plus `extraSeconds`) with two picture files.
        func addCapture(id: String, at date: Date, bytes: Int = 100) throws {
            let image = makeImageRecord(eventID: id, id: "\(id)-img")
            let folder = CaptureFileStore.monthFolder(for: date)
            let full = "captures/\(folder)/\(id)/\(id)-img-full.heic", model = "captures/\(folder)/\(id)/\(id)-img-model.heic"
            for path in [full, model] {
                let url = context.paths.root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: bytes).write(to: url)
            }
            var record = image
            record.fullPath = full
            record.modelPath = model
            try context.store!.insert(event: makeEventRecord(id: id, at: date), images: [record])
        }

        func folderExists(_ id: String, at date: Date) -> Bool {
            FileManager.default.fileExists(atPath: context.paths.captures
                .appendingPathComponent(CaptureFileStore.monthFolder(for: date)).appendingPathComponent(id).path)
        }
    }

    @Test func previewCountsAndSizesTheCapturesOlderThanTheCutoff() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-40 * day), bytes: 100)
        try h.addCapture(id: "new", at: now.addingTimeInterval(-5 * day), bytes: 100)
        let preview = try h.cleanup.preview(olderThanDays: 30)
        #expect(preview == CleanupService.Preview(captureCount: 1, bytes: 200))
        #expect(try h.cleanup.preview(olderThanDays: nil) == CleanupService.Preview(captureCount: 2, bytes: 400))
        #expect(try h.context.store?.count() == 2)        // a preview changes nothing
    }

    @Test func deleteRemovesExactlyTheOlderCapturesWithTheirFiles() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        let old = now.addingTimeInterval(-40 * day), recent = now.addingTimeInterval(-5 * day)
        try h.addCapture(id: "old", at: old)
        try h.addCapture(id: "new", at: recent)
        #expect(try h.cleanup.delete(olderThanDays: 30) == 1)
        #expect(try h.context.store?.events(olderThan: nil).map(\.id) == ["new"])
        #expect(try h.context.store?.allImages().map(\.eventId) == ["new"])
        #expect(!h.folderExists("old", at: old))
        #expect(h.folderExists("new", at: recent))
    }

    @Test func aCaptureExactlyAtTheCutoffIsKept() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "edge", at: now.addingTimeInterval(-30 * day))
        #expect(try h.cleanup.delete(olderThanDays: 30) == 0)
        #expect(try h.context.store?.count() == 1)
    }

    @Test func deleteAllRemovesEveryCapture() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "a", at: now.addingTimeInterval(-1 * day))
        try h.addCapture(id: "b", at: now.addingTimeInterval(-50 * day))
        #expect(try h.cleanup.delete(olderThanDays: nil) == 2)
        #expect(try h.context.store?.count() == 0)
        #expect(try h.context.store?.allImages().isEmpty == true)
        #expect(StorageStats.bytes(under: h.context.paths.captures) == 0)
    }

    @Test func nothingMatchingDeletesNothing() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "new", at: now.addingTimeInterval(-1 * day))
        #expect(try h.cleanup.preview(olderThanDays: 30) == CleanupService.Preview(captureCount: 0, bytes: 0))
        #expect(try h.cleanup.delete(olderThanDays: 30) == 0)
    }

    @Test func nothingDerivedFromCapturesIsTouched() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-99 * day))
        // Stand-ins for later items and their evidence crops (FR-023).
        let crop = h.context.paths.root.appendingPathComponent("evidence/crop.heic")
        try FileManager.default.createDirectory(at: crop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("crop".utf8).write(to: crop)
        try h.context.store?.withSentinelTable { db in
            try db.execute(sql: "CREATE TABLE items (id TEXT, evidence_path TEXT)")
            try db.execute(sql: "INSERT INTO items VALUES ('item-1', 'evidence/crop.heic')")
        }
        #expect(try h.cleanup.delete(olderThanDays: nil) == 1)
        #expect(FileManager.default.fileExists(atPath: crop.path))
        #expect(try h.context.store?.sentinelCount() == 1)
    }

    @Test func aCaptureInProgressIsNeverRemoved() throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        let staging = try h.context.files.makeStagingDirectory()
        try Data(count: 10).write(to: staging.appendingPathComponent("half-written.heic"))
        try h.addCapture(id: "old", at: now.addingTimeInterval(-99 * day))
        #expect(try h.cleanup.delete(olderThanDays: nil) == 1)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("half-written.heic").path))
    }

    @Test func aCleanupDuringACaptureLeavesTheNewCaptureIntact() async throws {
        let h = try Harness(now: now); defer { h.temp.cleanUp() }
        try h.addCapture(id: "old", at: now.addingTimeInterval(-99 * day))
        let pipeline = CapturePipeline(
            capturer: FakeDisplayCapturer(displays: [makeDisplay()], delay: .milliseconds(300)),
            encoder: HEICImageEncoder(), disk: FakeDiskSpace(), files: h.context.files, store: h.context.store!,
            paths: h.context.paths, settings: StorageSettings(store: FakeSettingsStore()), time: h.time)
        async let outcome = pipeline.run(trigger: .shortcut)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try h.cleanup.delete(olderThanDays: nil) == 1)
        #expect(await outcome == .complete(displays: 1))
        #expect(try h.context.store?.count() == 1)
        let report = try h.context.files.reconcile(with: h.context.store!)
        #expect(report == ReconcileReport(stagingRemoved: 0, orphansRemoved: 0, markedMissing: 0))
    }
}

// Test-only access to a table outside the two capture tables.
extension CaptureStore {
    func withSentinelTable(_ body: (Database) throws -> Void) throws {
        try database.pool.write { try body($0) }
    }
    func sentinelCount() throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") ?? 0 }
    }
}
