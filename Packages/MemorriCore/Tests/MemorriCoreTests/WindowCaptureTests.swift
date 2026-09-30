import Foundation
import Testing
@testable import MemorriCore

@Suite struct WindowCaptureTests {
    private func window(_ title: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> WindowInfo {
        WindowInfo(appName: "App", bundleID: "com.example.app", title: title, frame: PixelBox(x: x, y: y, width: w, height: h))
    }

    @Test func windowsAreOrderedLargestVisibleAreaFirst() {
        let list = [window("small", 0, 0, 100, 100), window("big", 0, 0, 800, 600), window("medium", 0, 0, 300, 300)]
        #expect(WindowSelection.select(list, pictureWidth: 1000, pictureHeight: 1000).compactMap(\.title) == ["big", "medium", "small"])
    }

    @Test func equalAreasKeepTheirOriginalOrder() {
        let list = [window("a", 0, 0, 100, 100), window("b", 200, 0, 100, 100), window("c", 400, 0, 100, 100)]
        #expect(WindowSelection.select(list, pictureWidth: 1000, pictureHeight: 1000).compactMap(\.title) == ["a", "b", "c"])
    }

    @Test func atMostTwentyAreKeptAndTheSmallestAreDropped() {
        let list = (1...25).map { window("w\($0)", 0, 0, $0 * 10, $0 * 10) }
        let kept = WindowSelection.select(list, pictureWidth: 1000, pictureHeight: 1000)
        #expect(kept.count == 20 && WindowSelection.maximum == 20)
        #expect(kept.first?.title == "w25" && kept.last?.title == "w6")
    }

    @Test func framesAreClippedToThePicture() {
        let kept = WindowSelection.select([window("edge", 900, -50, 300, 200)], pictureWidth: 1000, pictureHeight: 800)
        #expect(kept.first?.frame == PixelBox(x: 900, y: 0, width: 100, height: 150))
    }

    @Test func clippingDecidesTheOrderBecauseOnlyTheVisibleAreaCounts() {
        let hanging = window("mostly off screen", 900, 0, 2000, 2000)       // 100 x 800 visible
        let inside = window("inside", 0, 0, 300, 300)                          // 90 000 visible
        #expect(WindowSelection.select([hanging, inside], pictureWidth: 1000, pictureHeight: 800).compactMap(\.title) == ["inside", "mostly off screen"])
    }

    @Test func aWindowOutsideThePictureOrWithoutAreaIsDropped() {
        let list = [window("outside", 2000, 2000, 100, 100), window("flat", 10, 10, 0, 50), window("inside", 10, 10, 50, 50)]
        #expect(WindowSelection.select(list, pictureWidth: 1000, pictureHeight: 800).compactMap(\.title) == ["inside"])
    }

    @Test func noWindowsIsFine() {
        #expect(WindowSelection.select([], pictureWidth: 100, pictureHeight: 100).isEmpty)
    }

    @Test func aFailingInsertLeavesNoWindowsBehind() throws {
        let temp = TempDirectory()
        defer { temp.cleanUp() }
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        let store = CaptureStore(database: db)
        let event = CaptureEventRecord(id: "e", capturedAt: Date(), trigger: "shortcut", status: "complete", failureReason: nil, displayCount: 1)
        func image(_ id: String) -> CaptureImageRecord {
            CaptureImageRecord(id: id, eventId: "e", displayId: 1, displayName: nil, pixelWidth: 10, pixelHeight: 10, scale: 1,
                               fullPath: "f-\(id)", modelPath: "m-\(id)", modelWidth: 10, modelHeight: 10, fullBytes: 1, modelBytes: 1, missing: false)
        }
        #expect(throws: (any Error).self) {
            try store.insert(event: event, images: [image("a"), image("a")], windows: ["a": [window("x", 0, 0, 5, 5)]])
        }
        #expect(try store.windows(imageID: "a").isEmpty)
        #expect(try store.allImages().isEmpty)
    }
}
