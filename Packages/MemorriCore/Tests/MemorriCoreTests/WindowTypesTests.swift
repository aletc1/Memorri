import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct WindowTypesTests {
    private func opened(_ temp: TempDirectory) throws -> StorageDatabase {
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        return db
    }

    @Test func aPixelBoxHasItsCentreAndRoundTripsThroughJSON() throws {
        let box = PixelBox(x: 10, y: 20, width: 100, height: 40)
        #expect(box.midX == 60 && box.midY == 40)
        let decoded = try JSONDecoder().decode(PixelBox.self, from: JSONEncoder().encode(box))
        #expect(decoded == box)
    }

    @Test func aWindowKeepsItsApplicationTitleAndFrame() {
        let window = WindowInfo(appName: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", title: "Calendar",
                                frame: PixelBox(x: 0, y: 0, width: 800, height: 600))
        #expect(window.appName == "Microsoft Outlook" && window.bundleID == "com.microsoft.Outlook" && window.title == "Calendar")
        #expect(window == WindowInfo(appName: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", title: "Calendar",
                                     frame: PixelBox(x: 0, y: 0, width: 800, height: 600)))
    }

    @Test func aCapturedDisplayHasNoWindowsByDefault() {
        #expect(makeDisplay().windows.isEmpty)
    }

    @Test func windowsAreStoredWithTheImagesAndReadBackInOrder() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = CaptureStore(database: try opened(temp))
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        let windows = [WindowInfo(appName: "A", bundleID: "a", title: "first", frame: PixelBox(x: 0, y: 0, width: 10, height: 10)),
                       WindowInfo(appName: "B", bundleID: nil, title: nil, frame: PixelBox(x: 5, y: 5, width: 20, height: 20))]
        try store.insert(event: event, images: [image], windows: [image.id: windows])
        #expect(try store.windows(imageID: image.id) == windows)
        #expect(try store.windows(imageID: "unknown").isEmpty)
    }

    @Test func theOldInsertFormStillWorksAndStoresNoWindows() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = CaptureStore(database: try opened(temp))
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [image])
        #expect(try store.windows(imageID: image.id).isEmpty)
        #expect(try store.count() == 1)
    }

    @Test func aFailingWindowInsertLeavesNothingBehind() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = CaptureStore(database: try opened(temp))
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        let window = WindowInfo(appName: "A", bundleID: nil, title: nil, frame: PixelBox(x: 0, y: 0, width: 1, height: 1))
        // A window for a picture that is not in this capture breaks the foreign key: the whole insert rolls back.
        #expect(throws: (any Error).self) { try store.insert(event: event, images: [image], windows: ["missing-image": [window]]) }
        #expect(try store.count() == 0)
    }

    @Test func deletingTheCaptureRemovesItsWindows() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try opened(temp)
        let store = CaptureStore(database: db)
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        let window = WindowInfo(appName: "A", bundleID: nil, title: "t", frame: PixelBox(x: 0, y: 0, width: 1, height: 1))
        try store.insert(event: event, images: [image], windows: [image.id: [window]])
        try store.deleteEvents(ids: [event.id])
        let rows = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_windows") }
        #expect(rows == 0)
    }
}
