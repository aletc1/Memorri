import Foundation
import Testing
@testable import MemorriCore

@Suite struct StoredPictureProviderTests {
    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let provider: StoredPictureProvider

        init() throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            provider = StoredPictureProvider(paths: context.paths, store: context.store!)
        }

        /// A stored capture whose analysis copy file holds `bytes`.
        func addImage(id: String, bytes: Data, writeFile: Bool = true) throws -> CaptureImageRecord {
            let event = makeEventRecord(id: "event-\(id)")
            var image = makeImageRecord(eventID: event.id, id: id)
            image.modelWidth = 2048; image.modelHeight = 857
            if writeFile {
                let url = context.paths.root.appendingPathComponent(image.modelPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url)
            }
            try context.store!.insert(event: event, images: [image])
            return image
        }
    }

    @Test func readsTheAnalysisCopyWithItsSize() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let bytes = Data("analysis copy".utf8)
        let image = try h.addImage(id: "a", bytes: bytes)
        let picture = try #require(try h.provider.analysisPicture(imageID: image.id))
        #expect(picture.data == bytes)
        #expect(picture.width == 2048 && picture.height == 857 && picture.longEdge == 2048)
    }

    @Test func longEdgeIsTheLongerSideForLandscapeAndPortrait() {
        #expect(StoredPicture(data: Data(), width: 2048, height: 857).longEdge == 2048)
        #expect(StoredPicture(data: Data(), width: 857, height: 2048).longEdge == 2048)
    }

    @Test func returnsNilWhenTheRecordIsGone() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        #expect(try h.provider.analysisPicture(imageID: "unknown") == nil)
        let image = try h.addImage(id: "a", bytes: Data("x".utf8))
        try h.context.store!.deleteEvents(ids: [image.eventId])
        #expect(try h.provider.analysisPicture(imageID: image.id) == nil)
    }

    @Test func returnsNilWhenTheFileIsMissing() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let image = try h.addImage(id: "a", bytes: Data(), writeFile: false)
        #expect(try h.provider.analysisPicture(imageID: image.id) == nil)
    }

    @Test func returnsNilWhenTheRecordIsMarkedMissing() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let image = try h.addImage(id: "a", bytes: Data("x".utf8))
        try h.context.store!.markMissing(imageID: image.id)
        #expect(try h.provider.analysisPicture(imageID: image.id) == nil)
    }

    // MARK: Full-resolution copy

    private func addFullImage(_ h: Harness, id: String, size: (Int, Int), writeFile: Bool = true, bytes: Data? = nil) throws -> CaptureImageRecord {
        let event = makeEventRecord(id: "event-\(id)")
        var image = makeImageRecord(eventID: event.id, id: id)
        image.pixelWidth = size.0; image.pixelHeight = size.1
        if writeFile {
            let url = h.context.paths.root.appendingPathComponent(image.fullPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (bytes ?? makeHEICData(width: size.0, height: size.1)).write(to: url)
        }
        try h.context.store!.insert(event: event, images: [image])
        return image
    }

    @Test func fullPictureDecodesToTheRecordedPixelSize() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let image = try addFullImage(h, id: "full", size: (1200, 500))
        let picture = try #require(try h.provider.fullPicture(imageID: image.id))
        #expect(picture.width == 1200 && picture.height == 500)
    }

    @Test func fullPictureIsNilForAMissingRowFileOrUnreadableFile() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        #expect(try h.provider.fullPicture(imageID: "unknown") == nil)
        let noFile = try addFullImage(h, id: "nofile", size: (100, 50), writeFile: false)
        #expect(try h.provider.fullPicture(imageID: noFile.id) == nil)
        let garbage = try addFullImage(h, id: "garbage", size: (100, 50), bytes: Data("not a picture".utf8))
        #expect(try h.provider.fullPicture(imageID: garbage.id) == nil)
        let gone = try addFullImage(h, id: "gone", size: (100, 50))
        try h.context.store!.markMissing(imageID: gone.id)
        #expect(try h.provider.fullPicture(imageID: gone.id) == nil)
    }
}
