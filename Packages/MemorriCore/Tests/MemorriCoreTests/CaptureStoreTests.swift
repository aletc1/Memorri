import Foundation
import Testing
@testable import MemorriCore

@Suite struct CaptureStoreTests {
    private func makeStore(_ temp: TempDirectory) throws -> CaptureStore {
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw StoreTestError.notOpened }
        return CaptureStore(database: db)
    }
    private enum StoreTestError: Error { case notOpened }

    @Test func insertAndCount() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        #expect(try store.count() == 0)
        let event = makeEventRecord(displayCount: 2)
        try store.insert(event: event, images: [makeImageRecord(eventID: event.id), makeImageRecord(eventID: event.id)])
        #expect(try store.count() == 1)
        #expect(try store.allImages().count == 2)
    }

    @Test func insertIsOneTransaction() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord()
        let duplicateImageID = UUID().uuidString
        #expect(throws: (any Error).self) {
            try store.insert(event: event, images: [makeImageRecord(eventID: event.id, id: duplicateImageID),
                                                    makeImageRecord(eventID: event.id, id: duplicateImageID)])
        }
        #expect(try store.count() == 0)
    }

    @Test func aCaptureIsAFullScreenCaptureUnlessItSaysItIsAWindow() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let screens = makeEventRecord(), window = makeEventRecord(scope: .window)
        let screenImage = makeImageRecord(eventID: screens.id), windowImage = makeImageRecord(eventID: window.id)
        try store.insert(event: screens, images: [screenImage])
        try store.insert(event: window, images: [windowImage])
        #expect(screens.scope == .displays && window.scope == .window)
        #expect(try store.scope(imageID: screenImage.id) == .displays)
        #expect(try store.scope(imageID: windowImage.id) == .window)
        #expect(try store.scope(imageID: "unknown") == .displays)
        #expect(try store.events(olderThan: nil).map(\.scope).sorted { $0.rawValue < $1.rawValue } == [.displays, .window])
    }

    @Test func aWindowCaptureKeepsItsFrameOnTheDesktopAndOneWindowThatFillsThePicture() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord(scope: .window)
        let frame = DesktopRect(x: -1200.5, y: 40, width: 900, height: 700.25)
        var image = makeImageRecord(eventID: event.id)
        image.desktopFrame = frame
        let window = WindowInfo(appName: "Mail", bundleID: "com.example.mail", title: "Inbox",
                                frame: PixelBox(x: 0, y: 0, width: image.pixelWidth, height: image.pixelHeight), stack: 0)
        try store.insert(event: event, images: [image], windows: [image.id: [window]])
        let read = try #require(try store.image(id: image.id))
        #expect(read.desktopFrame == frame)
        #expect(read == image)
        #expect(try store.windows(imageID: image.id) == [window])
        #expect(try store.allImages().count == 1)
    }

    @Test func aDisplayPictureHasNoDesktopFrame() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [image])
        #expect(try store.image(id: image.id)?.desktopFrame == nil)
    }

    @Test func eventsOlderThanUsesAStrictCutoff() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let old = makeEventRecord(at: cutoff.addingTimeInterval(-60))
        let boundary = makeEventRecord(at: cutoff)
        let recent = makeEventRecord(at: cutoff.addingTimeInterval(60))
        for event in [old, boundary, recent] { try store.insert(event: event, images: []) }
        #expect(try store.events(olderThan: cutoff).map(\.id) == [old.id])
        #expect(try store.events(olderThan: nil).count == 3)
    }

    @Test func deleteEventsRemovesOnlyTheGivenOnes() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let a = makeEventRecord(), b = makeEventRecord()
        try store.insert(event: a, images: [])
        try store.insert(event: b, images: [])
        try store.deleteEvents(ids: [a.id])
        #expect(try store.events(olderThan: nil).map(\.id) == [b.id])
    }

    @Test func markMissingFlagsOneImage() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord()
        let first = makeImageRecord(eventID: event.id), second = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [first, second])
        try store.markMissing(imageID: first.id)
        let images = try store.allImages()
        #expect(images.first { $0.id == first.id }?.missing == true)
        #expect(images.first { $0.id == second.id }?.missing == false)
    }

    @Test func recordsRoundTrip() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord(trigger: "menu", status: "failed", failureReason: "Not enough free disk space", displayCount: 0)
        let image = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [image])
        #expect(try store.events(olderThan: nil) == [event])
        #expect(try store.allImages() == [image])
    }

    // MARK: lookups for the analysis queue (spec 003)

    @Test func imageByIDReturnsTheRecordOrNil() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [image])
        #expect(try store.image(id: image.id) == image)
        #expect(try store.image(id: "unknown") == nil)
    }

    @Test func newestImageIDIsFromTheNewestEventThatHasImages() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        #expect(try store.newestImageID() == nil)
        let older = makeEventRecord(id: "older", at: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = makeEventRecord(id: "newer", at: Date(timeIntervalSince1970: 1_800_000_100))
        let failedNewest = makeEventRecord(id: "failed", at: Date(timeIntervalSince1970: 1_800_000_200), status: "failed", displayCount: 0)
        try store.insert(event: older, images: [makeImageRecord(eventID: "older", id: "img-older")])
        try store.insert(event: newer, images: [makeImageRecord(eventID: "newer", id: "img-newer", displayID: 2),
                                                makeImageRecord(eventID: "newer", id: "img-newer-first", displayID: 1)])
        try store.insert(event: failedNewest, images: [])
        #expect(try store.newestImageID() == "img-newer-first")      // first display of the newest event with pictures
    }

    @Test func newestImageIDSkipsPicturesMarkedMissing() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let store = try makeStore(temp)
        let older = makeEventRecord(id: "older", at: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = makeEventRecord(id: "newer", at: Date(timeIntervalSince1970: 1_800_000_100))
        try store.insert(event: older, images: [makeImageRecord(eventID: "older", id: "img-older")])
        try store.insert(event: newer, images: [makeImageRecord(eventID: "newer", id: "img-newer")])
        try store.markMissing(imageID: "img-newer")
        #expect(try store.newestImageID() == "img-older")
    }
}
