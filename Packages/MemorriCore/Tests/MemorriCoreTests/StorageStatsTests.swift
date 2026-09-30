import Foundation
import Testing
@testable import MemorriCore

@Suite struct StorageStatsTests {
    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let stats: StorageStats

        init() throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            stats = StorageStats(paths: context.paths, store: context.store!)
        }

        func addCapture(id: String, fullBytes: Int, modelBytes: Int) throws {
            let event = makeEventRecord(id: id)
            let image = makeImageRecord(eventID: id, id: "\(id)-img")
            for (path, size) in [(image.fullPath, fullBytes), (image.modelPath, modelBytes)] {
                let url = context.paths.root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: size).write(to: url)
            }
            try context.store!.insert(event: event, images: [image])
        }
    }

    @Test func anEmptyStoreReportsZeroCapturesAndPictures() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let summary = try h.stats.summary()
        #expect(summary.captureCount == 0 && summary.pictureBytes == 0)
    }

    @Test func countsCapturesAndSumsThePictureFilesOnDisk() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "a", fullBytes: 1000, modelBytes: 400)
        try h.addCapture(id: "b", fullBytes: 2000, modelBytes: 600)
        let summary = try h.stats.summary()
        #expect(summary.captureCount == 2)
        #expect(summary.pictureBytes == 4000)
    }

    @Test func aFileChangedOutsideTheAppIsReflected() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "a", fullBytes: 1000, modelBytes: 400)
        let image = try #require(try h.context.store?.allImages().first)
        try Data(count: 5000).write(to: h.context.paths.root.appendingPathComponent(image.fullPath))
        #expect(try h.stats.summary().pictureBytes == 5400)
    }

    @Test func databaseBytesCoverTheMainFileAndItsWalAndShmFiles() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.addCapture(id: "a", fullBytes: 10, modelBytes: 10)
        let paths = h.context.paths
        let expected = ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: paths.database.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let summary = try h.stats.summary()
        #expect(summary.databaseBytes == expected)
        #expect(summary.databaseBytes > 0)
    }
}
