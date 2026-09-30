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
}
