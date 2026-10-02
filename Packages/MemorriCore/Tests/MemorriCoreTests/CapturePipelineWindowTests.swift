import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct CapturePipelineWindowTests {
    struct Rig {
        let temp = TempDirectory()
        let paths: AppPaths
        let files: CaptureFileStore
        let store: CaptureStore
        let settingsStore = FakeSettingsStore()
        let pipeline: CapturePipeline
        let displays = FakeDisplayCapturer(displays: [makeDisplay()])
        let outliner = FakeOutliner()
        let enqueuer = FakeEnqueuer()

        init(window: FakeWindowCapturer, disk: FakeDiskSpace = FakeDiskSpace(), failingStore: Bool = false, encoder: any ImageEncoding = HEICImageEncoder(),
             automatic: Bool? = nil) throws {
            paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
            try paths.prepare()
            files = CaptureFileStore(paths: paths)
            guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
            store = CaptureStore(database: db)
            pipeline = CapturePipeline(capturer: displays, encoder: encoder, disk: disk, files: files,
                                       store: failingStore ? FailingStore() : store, paths: paths,
                                       settings: StorageSettings(store: settingsStore), time: FakeTimeSource(),
                                       enqueuer: enqueuer, analysisSettings: AnalysisSettings(store: settingsStore),
                                       windowCapturer: window, outliner: outliner)
            if let automatic { AnalysisSettings(store: settingsStore).setAutomatic(automatic) }
        }

        var stagingEntries: Int { ((try? FileManager.default.contentsOfDirectory(atPath: paths.staging.path)) ?? []).count }

        func pictureWidth(_ relative: String) -> Int? {
            let url = paths.root.appendingPathComponent(relative)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image.width
        }
    }

    @Test func aWindowCaptureStoresOneEventWithOneWindowPicture() async throws {
        let frame = DesktopRect(x: -300, y: 20, width: 640, height: 480.5)
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(width: 1280, height: 960, scale: 2, displayID: 7, frame: frame)))
        defer { rig.temp.cleanUp() }
        let outcome = await rig.pipeline.runWindow(trigger: .shortcut)
        #expect(outcome == .windowComplete(app: "Mail"))
        let events = try rig.store.events(olderThan: nil)
        #expect(events.count == 1)
        #expect(events[0].scope == .window && events[0].status == "complete" && events[0].displayCount == 1 && events[0].trigger == "shortcut")
        let images = try rig.store.allImages()
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.displayId == 7 && image.scale == 2 && image.pixelWidth == 1280 && image.pixelHeight == 960)
        #expect(image.desktopFrame == frame)
        #expect(rig.pictureWidth(image.fullPath) == 1280)
        #expect(rig.pictureWidth(image.modelPath) == 1280)   // never enlarged
        #expect(!image.missing)
        #expect(rig.stagingEntries == 0)
        #expect(rig.displays.callCount == 0)
    }

    @Test func theWindowIsRecordedAsOneWindowThatFillsThePicture() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(width: 1280, height: 960, app: "Mail", title: "Inbox")))
        defer { rig.temp.cleanUp() }
        _ = await rig.pipeline.runWindow(trigger: .menu)
        let image = try #require(try rig.store.allImages().first)
        let windows = try rig.store.windows(imageID: image.id)
        #expect(windows == [WindowInfo(appName: "Mail", bundleID: "com.example.mail", title: "Inbox",
                                       frame: PixelBox(x: 0, y: 0, width: 1280, height: 960), stack: 0)])
        #expect(try rig.store.events(olderThan: nil).first?.trigger == "menu")
    }

    @Test func theAnalysisCopyFollowsTheSetting() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(width: 3000, height: 2000)))
        defer { rig.temp.cleanUp() }
        #expect(StorageSettings(store: rig.settingsStore).setModelLongEdge(1024))
        _ = await rig.pipeline.runWindow(trigger: .menu)
        #expect(try rig.store.allImages().first?.modelWidth == 1024)
    }

    @Test func analysisIsQueuedAtTheUsualPlaceWhenAutomatic() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture()))
        defer { rig.temp.cleanUp() }
        _ = await rig.pipeline.runWindow(trigger: .shortcut)
        let ids = try rig.store.allImages().map(\.id)
        #expect(rig.enqueuer.calls == [ids])
    }

    @Test func analysisIsNotQueuedWhenAutomaticAnalysisIsOff() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture()), automatic: false)
        defer { rig.temp.cleanUp() }
        _ = await rig.pipeline.runWindow(trigger: .shortcut)
        #expect(rig.enqueuer.calls.isEmpty)
    }

    @Test func noWindowStoresNothingAndSaysWhy() async throws {
        let none = try Rig(window: FakeWindowCapturer(failure: .noWindow))
        defer { none.temp.cleanUp() }
        #expect(await none.pipeline.runWindow(trigger: .shortcut) == .noWindow(.none))
        let own = try Rig(window: FakeWindowCapturer(failure: .ownWindow))
        defer { own.temp.cleanUp() }
        #expect(await own.pipeline.runWindow(trigger: .shortcut) == .noWindow(.ownWindow))
        for rig in [none, own] {
            #expect(try rig.store.count() == 0 && rig.stagingEntries == 0)
            #expect(rig.outliner.frames.isEmpty && rig.enqueuer.calls.isEmpty)
        }
    }

    @Test func aRefusedPermissionStoresNothingAndShowsNoOutline() async throws {
        let rig = try Rig(window: FakeWindowCapturer(failure: .permissionDenied))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.runWindow(trigger: .shortcut) == .permissionDenied)
        #expect(try rig.store.count() == 0)
        #expect(rig.outliner.frames.isEmpty)
    }

    @Test func aWindowThatClosedDuringTheCaptureFailsWithoutStoringAnything() async throws {
        let rig = try Rig(window: FakeWindowCapturer(failure: .other("the window is gone")))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.runWindow(trigger: .shortcut) == .failed(reason: "the window is gone"))
        #expect(try rig.store.count() == 0 && rig.stagingEntries == 0)
        #expect(rig.outliner.frames.isEmpty && rig.enqueuer.calls.isEmpty)
    }

    @Test func lessThanOneGiBFreeRefusesWithoutCapturingAndRecordsTheFailure() async throws {
        let window = FakeWindowCapturer(result: makeWindowCapture())
        let rig = try Rig(window: window, disk: FakeDiskSpace(free: CapturePipeline.minimumFreeBytes - 1))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.runWindow(trigger: .shortcut) == .failed(reason: "Not enough free disk space"))
        #expect(window.callCount == 0)
        let events = try rig.store.events(olderThan: nil)
        #expect(events.count == 1 && events[0].status == "failed" && events[0].scope == .window && events[0].displayCount == 0)
        #expect(try rig.store.allImages().isEmpty && rig.outliner.frames.isEmpty)
    }

    @Test func aFailedStoreLeavesNothingAndShowsNoOutline() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture()), failingStore: true)
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.runWindow(trigger: .shortcut) == .failed(reason: "could not save the pictures"))
        #expect(rig.stagingEntries == 0 && rig.outliner.frames.isEmpty && rig.enqueuer.calls.isEmpty)
        let months = (try? FileManager.default.contentsOfDirectory(atPath: rig.paths.captures.path)) ?? []
        #expect(months.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: rig.paths.captures.appendingPathComponent($0).path)) ?? [] }.isEmpty)
    }

    @Test func anEncodingFailureStoresNothingAndShowsNoOutline() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture()), encoder: FailingEncoder())
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.runWindow(trigger: .shortcut) == .failed(reason: "could not save the pictures"))
        #expect(rig.outliner.frames.isEmpty)
    }

    @Test func theOutlineIsShownOnceAfterThePictureIsStored() async throws {
        let frame = DesktopRect(x: 10, y: 20, width: 300, height: 200)
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(frame: frame)))
        defer { rig.temp.cleanUp() }
        let store = rig.store, paths = rig.paths
        let storedWhenShown = LockedBox<Bool?>(nil)
        rig.outliner.onShow = {
            let stored = ((try? store.count()) ?? 0) == 1 && !(((try? store.allImages()) ?? []).isEmpty)
            let exists = ((try? store.allImages()) ?? []).allSatisfy { FileManager.default.fileExists(atPath: paths.root.appendingPathComponent($0.fullPath).path) }
            storedWhenShown.set(stored && exists)
        }
        _ = await rig.pipeline.runWindow(trigger: .shortcut)
        #expect(rig.outliner.frames == [frame])
        #expect(storedWhenShown.value == true)
    }

    @Test func aSecondRequestWhileOneRunsIsIgnoredAndTheFirstStillCompletes() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(), delay: .milliseconds(300)))
        defer { rig.temp.cleanUp() }
        async let first = rig.pipeline.runWindow(trigger: .shortcut)
        try await Task.sleep(for: .milliseconds(80))
        let second = await rig.pipeline.runWindow(trigger: .shortcut)
        #expect(second == nil)
        #expect(await first == .windowComplete(app: "Mail"))
        #expect(try rig.store.count() == 1)
    }

    @Test func aFullScreenRunInProgressBlocksAWindowRunAndTheOtherWayAround() async throws {
        let rig = try Rig(window: FakeWindowCapturer(result: makeWindowCapture(), delay: .milliseconds(300)))
        defer { rig.temp.cleanUp() }
        async let window = rig.pipeline.runWindow(trigger: .shortcut)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await rig.pipeline.run(trigger: .menu) == nil)
        #expect(await window == .windowComplete(app: "Mail"))
    }

    @Test func theFullScreenRunNeverTouchesTheWindowCapturer() async throws {
        let window = FakeWindowCapturer(result: makeWindowCapture())
        let rig = try Rig(window: window)
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .complete(displays: 1))
        #expect(window.callCount == 0 && rig.outliner.frames.isEmpty)
        let event = try #require(try rig.store.events(olderThan: nil).first)
        #expect(event.scope == .displays)
        #expect(try rig.store.allImages().first?.desktopFrame == nil)
    }
}

/// A value a closure can set and a test can read afterwards.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
