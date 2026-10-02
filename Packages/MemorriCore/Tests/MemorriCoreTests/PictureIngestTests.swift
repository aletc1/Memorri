import Foundation
import Testing
@testable import MemorriCore

@Suite struct PictureIngestTests {
    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let ingest: PictureIngest

        init(modelLongEdge: Int = 1024) throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            ingest = PictureIngest(paths: context.paths, files: context.files, store: context.store!, modelLongEdge: modelLongEdge,
                                   time: FakeTimeSource(5000))
        }
    }

    private func png(width: Int = 1600, height: Int = 1000) throws -> Data {
        let canvas = SyntheticCanvas(width: width, height: height, background: RGB(0xFFFFFF))
        canvas.text("Hello", x: 20, y: 20, size: 30, color: RGB(0x000000))
        return try canvas.pngData()
    }

    @Test func storesBothCopiesAndOneEventWithOneImage() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let id = try h.ingest.store(png: try png())
        let image = try #require(try h.context.store!.image(id: id))
        #expect(image.pixelWidth == 1600 && image.pixelHeight == 1000)
        #expect(image.modelWidth == 1024 && image.modelHeight == 640)
        #expect(image.scale == 1 && image.missing == false)
        for path in [image.fullPath, image.modelPath] {
            #expect(FileManager.default.fileExists(atPath: h.context.paths.root.appendingPathComponent(path).path))
        }
        let events = try h.context.store!.events(olderThan: nil)
        #expect(events.count == 1)
        #expect(events[0].trigger == "menu" && events[0].status == "complete" && events[0].displayCount == 1)
        #expect(events[0].id == image.eventId)
    }

    @Test func aPictureIngestedAsAWindowCaptureIsMarkedSo() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let window = WindowInfo(appName: "Mail", bundleID: "com.example.mail", title: "Inbox", frame: PixelBox(x: 0, y: 0, width: 1600, height: 1000), stack: 0)
        let id = try h.ingest.store(png: try png(), windows: [window], scope: .window)
        #expect(try h.context.store!.scope(imageID: id) == .window)
        #expect(try h.context.store!.windows(imageID: id) == [window])
        let plain = try h.ingest.store(png: try png())
        #expect(try h.context.store!.scope(imageID: plain) == .displays)
    }

    @Test func aSmallPictureIsNotEnlargedForTheAnalysisCopy() throws {
        let h = try Harness(modelLongEdge: 2048); defer { h.temp.cleanUp() }
        let image = try #require(try h.context.store!.image(id: try h.ingest.store(png: try png(width: 800, height: 500))))
        #expect(image.modelWidth == 800 && image.modelHeight == 500)
    }

    @Test func storesTheGivenWindows() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let windows = [WindowInfo(appName: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", title: "Calendar",
                                  frame: PixelBox(x: 0, y: 0, width: 1600, height: 1000))]
        let id = try h.ingest.store(png: try png(), windows: windows)
        #expect(try h.context.store!.windows(imageID: id) == windows)
    }

    @Test func aFileThatIsNotAPictureGivesAnErrorAndWritesNothing() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        #expect(throws: PictureIngestError.notAPicture) { try h.ingest.store(png: Data("not a picture".utf8)) }
        #expect(try h.context.store!.count() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.context.paths.captures.path).isEmpty)
    }
}
