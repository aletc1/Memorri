import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct CapturePipelineTests {
    struct Rig {
        let temp = TempDirectory()
        let paths: AppPaths
        let files: CaptureFileStore
        let database: StorageDatabase
        let store: CaptureStore
        let settingsStore = FakeSettingsStore()
        let pipeline: CapturePipeline
        let capturer: FakeDisplayCapturer

        init(capturer: FakeDisplayCapturer, disk: FakeDiskSpace = FakeDiskSpace(),
             encoder: any ImageEncoding = HEICImageEncoder(), failingStore: Bool = false) throws {
            paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
            try paths.prepare()
            files = CaptureFileStore(paths: paths)
            guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
            database = db
            store = CaptureStore(database: db)
            self.capturer = capturer
            pipeline = CapturePipeline(capturer: capturer, encoder: encoder, disk: disk, files: files,
                                       store: failingStore ? FailingStore() : store, paths: paths,
                                       settings: StorageSettings(store: settingsStore), time: FakeTimeSource())
        }

        var stagingEntries: Int { ((try? FileManager.default.contentsOfDirectory(atPath: paths.staging.path)) ?? []).count }

        /// Event folders under captures/<month>/.
        var captureFolders: [String] {
            let months = (try? FileManager.default.contentsOfDirectory(atPath: paths.captures.path)) ?? []
            return months.flatMap { month in
                ((try? FileManager.default.contentsOfDirectory(atPath: paths.captures.appendingPathComponent(month).path)) ?? [])
                    .map { "\(month)/\($0)" }
            }
        }

        func pictureWidth(_ relative: String) -> Int? {
            let url = paths.root.appendingPathComponent(relative)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return image.width
        }
    }

    @Test func threeDisplaysGiveThreeFullAndThreeAnalysisPicturesInOneEvent() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay(id: 1), makeDisplay(id: 2), makeDisplay(id: 3)]))
        defer { rig.temp.cleanUp() }
        let outcome = await rig.pipeline.run(trigger: .shortcut)
        #expect(outcome == .complete(displays: 3))
        let events = try rig.store.events(olderThan: nil)
        #expect(events.count == 1)
        #expect(events[0].status == "complete" && events[0].displayCount == 3 && events[0].trigger == "shortcut")
        let images = try rig.store.allImages()
        #expect(images.count == 3)
        for image in images {
            #expect(rig.pictureWidth(image.fullPath) == 3440)
            #expect(rig.pictureWidth(image.modelPath) == 2048)
            #expect(!image.missing)
        }
        #expect(rig.stagingEntries == 0)
        #expect(rig.captureFolders.count == 1)
    }

    @Test func theAnalysisCopyFollowsTheSettingAndIsNeverEnlarged() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay(id: 1), makeDisplay(id: 2, width: 1000, height: 600)]))
        defer { rig.temp.cleanUp() }
        #expect(StorageSettings(store: rig.settingsStore).setModelLongEdge(1024))
        _ = await rig.pipeline.run(trigger: .menu)
        let widths = try rig.store.allImages().map(\.modelWidth).sorted()
        #expect(widths == [1000, 1024])
    }

    @Test func aSecondRunWhileOneIsInProgressIsIgnored() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()], delay: .milliseconds(300)))
        defer { rig.temp.cleanUp() }
        async let first = rig.pipeline.run(trigger: .shortcut)
        try await Task.sleep(for: .milliseconds(80))
        let second = await rig.pipeline.run(trigger: .shortcut)
        #expect(second == nil)
        #expect(await first == .complete(displays: 1))
        #expect(rig.capturer.callCount == 1)
        #expect(try rig.store.count() == 1)
    }

    @Test func lessThanOneGiBFreeRefusesWithoutCapturing() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()]),
                          disk: FakeDiskSpace(free: CapturePipeline.minimumFreeBytes - 1))
        defer { rig.temp.cleanUp() }
        let outcome = await rig.pipeline.run(trigger: .shortcut)
        #expect(outcome == .failed(reason: "Not enough free disk space"))
        #expect(rig.capturer.callCount == 0)
        let events = try rig.store.events(olderThan: nil)
        #expect(events.count == 1 && events[0].status == "failed" && events[0].displayCount == 0)
        #expect(events[0].failureReason == "Not enough free disk space")
        #expect(try rig.store.allImages().isEmpty)
    }

    @Test func exactlyOneGiBFreeIsEnough() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()]),
                          disk: FakeDiskSpace(free: CapturePipeline.minimumFreeBytes))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .complete(displays: 1))
    }

    @Test func aFailedDisplayGivesAPartialCaptureAndKeepsTheOthers() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay(id: 1), makeDisplay(id: 2)], failedDisplayCount: 1))
        defer { rig.temp.cleanUp() }
        let outcome = await rig.pipeline.run(trigger: .shortcut)
        #expect(outcome == .partial(captured: 2, of: 3))
        let events = try rig.store.events(olderThan: nil)
        #expect(events[0].status == "partial" && events[0].displayCount == 3)
        #expect(events[0].failureReason == "1 of 3 displays could not be captured")
        #expect(try rig.store.allImages().count == 2)
    }

    @Test func noDisplayGivesAShortFailure() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(failure: .noDisplays))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .failed(reason: "no display available"))
        #expect(try rig.store.events(olderThan: nil).first?.status == "failed")
    }

    @Test func anotherCaptureErrorIsReportedWithItsMessage() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(failure: .other("display went away")))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .failed(reason: "display went away"))
    }

    @Test func aFailingEncoderLeavesNothingButAFailedEvent() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()]), encoder: FailingEncoder())
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .failed(reason: "could not save the pictures"))
        let events = try rig.store.events(olderThan: nil)
        #expect(events.count == 1 && events[0].status == "failed")
        #expect(events[0].failureReason == "could not save the pictures")
        #expect(try rig.store.allImages().isEmpty)
        #expect(rig.stagingEntries == 0 && rig.captureFolders.isEmpty)
    }

    @Test func aFailingStoreLeavesNoFilesAndNoRecords() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()]), failingStore: true)
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .failed(reason: "could not save the pictures"))
        #expect(try rig.store.count() == 0)
        #expect(rig.stagingEntries == 0 && rig.captureFolders.isEmpty)
    }

    @Test func aDeletedDataFolderIsRecreatedOnTheNextRun() async throws {
        let rig = try Rig(capturer: FakeDisplayCapturer(displays: [makeDisplay()]))
        defer { rig.temp.cleanUp() }
        #expect(await rig.pipeline.run(trigger: .shortcut) == .complete(displays: 1))
        try FileManager.default.removeItem(at: rig.paths.captures)
        try FileManager.default.removeItem(at: rig.paths.staging)
        #expect(await rig.pipeline.run(trigger: .shortcut) == .complete(displays: 1))
        #expect(rig.captureFolders.count == 1)
    }
}
