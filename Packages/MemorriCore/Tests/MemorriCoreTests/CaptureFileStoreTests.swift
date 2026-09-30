import Foundation
import Testing
@testable import MemorriCore

@Suite struct CaptureFileStoreTests {
    private struct Harness {
        let temp = TempDirectory()
        let paths: AppPaths
        let files: CaptureFileStore
        let store: CaptureStore

        init() throws {
            paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
            try paths.prepare()
            files = CaptureFileStore(paths: paths)
            guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
            store = CaptureStore(database: db)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(relative).path)
        }

        func write(_ relative: String) throws {
            let url = paths.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC

    @Test func stagingDirectoriesAreUniqueAndUnderStaging() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let a = try h.files.makeStagingDirectory(), b = try h.files.makeStagingDirectory()
        #expect(a != b)
        #expect(a.deletingLastPathComponent().path == h.paths.staging.path)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func commitMovesTheStagingDirectoryIntoTheMonthFolder() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let staging = try h.files.makeStagingDirectory()
        try Data("x".utf8).write(to: staging.appendingPathComponent("a-full.heic"))
        let final = try h.files.commit(staging: staging, eventID: "event-1", capturedAt: capturedAt)
        #expect(final.path == h.paths.captures.appendingPathComponent("2027-01/event-1").path)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("a-full.heic").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func discardRemovesAStagingDirectory() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let staging = try h.files.makeStagingDirectory()
        h.files.discard(staging: staging)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func removeCaptureDirectoryRemovesTheFinalFolder() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let staging = try h.files.makeStagingDirectory()
        let final = try h.files.commit(staging: staging, eventID: "event-1", capturedAt: capturedAt)
        h.files.removeCaptureDirectory(eventID: "event-1", capturedAt: capturedAt)
        #expect(!FileManager.default.fileExists(atPath: final.path))
    }

    @Test func reconcileEmptiesStagingAndRemovesDirectoriesWithoutARecord() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        _ = try h.files.makeStagingDirectory()
        try h.write("captures/2027-01/orphan-event/x-full.heic")
        let report = try h.files.reconcile(with: h.store)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.paths.staging.path).isEmpty)
        #expect(!h.exists("captures/2027-01/orphan-event"))
        #expect(report.stagingRemoved == 1 && report.orphansRemoved == 1 && report.markedMissing == 0)
    }

    @Test func reconcileMarksRecordsWhoseFileIsGone() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let event = makeEventRecord(id: "event-1", at: capturedAt)
        let image = makeImageRecord(eventID: "event-1", id: "img")
        try h.store.insert(event: event, images: [image])
        try h.write(image.fullPath)                                  // the analysis copy is missing
        let report = try h.files.reconcile(with: h.store)
        #expect(try h.store.allImages().first?.missing == true)
        #expect(report.markedMissing == 1)
    }

    @Test func reconcileLeavesCompleteCapturesUntouched() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let event = makeEventRecord(id: "event-1", at: capturedAt)
        let image = makeImageRecord(eventID: "event-1", id: "img")
        try h.store.insert(event: event, images: [image])
        try h.write(image.fullPath)
        try h.write(image.modelPath)
        let report = try h.files.reconcile(with: h.store)
        #expect(try h.store.allImages().first?.missing == false)
        #expect(h.exists(image.fullPath) && h.exists(image.modelPath))
        #expect(report.stagingRemoved == 0 && report.orphansRemoved == 0 && report.markedMissing == 0)
    }
}
