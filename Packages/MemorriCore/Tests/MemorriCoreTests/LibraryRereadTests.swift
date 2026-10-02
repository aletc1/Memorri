import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct LibraryRereadTests {
    private let now = Date(timeIntervalSince1970: 1_800_500_000)

    private struct Rig {
        let fixture: PipelineFixture
        let settings: FakeSettingsStore
        let reread: LibraryReread
        let jobs: AnalysisStore
    }

    private func makeRig() throws -> Rig {
        let fixture = try makePipelineFixture()
        let settings = FakeSettingsStore()
        return Rig(fixture: fixture, settings: settings, reread: LibraryReread(database: fixture.database, settings: settings, paths: fixture.paths),
                   jobs: AnalysisStore(database: fixture.database))
    }

    /// A picture taken at `date`, with its analysis, and with its files on disk when `files` is true.
    @discardableResult
    private func addPicture(_ rig: Rig, at date: Date, files: Bool = true, analysed: Bool = true) throws -> String {
        let event = makeEventRecord(at: date)
        let image = makeImageRecord(eventID: event.id)
        if files {
            for path in [image.fullPath, image.modelPath] {
                let url = rig.fixture.paths.root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try makeHEICData(width: 40, height: 20).write(to: url)
            }
        }
        try rig.fixture.captures.insert(event: event, images: [image])
        if analysed { try analyse(rig, image.id) }
        return image.id
    }

    private func analyse(_ rig: Rig, _ id: String) throws {
        let classification = ClassificationResult(kind: .email, confidence: 0.9, application: "Mail", platformLook: "macos", isRemote: false, remoteClient: "", theme: "light", calendarName: "")
        try AnalysisResultStore(database: rig.fixture.database).save(AnalysisResult(lines: [], classification: classification), imageID: id, runID: nil, at: now)
    }

    private func queued(_ rig: Rig) throws -> [AnalysisJobRecord] {
        try rig.fixture.database.pool.read { try AnalysisJobRecord.fetchAll($0, sql: "SELECT * FROM analysis_jobs ORDER BY created_at, id") }
    }

    @Test func everyAnalysedPictureThatIsStillKeptGetsOneRereadJobOfPriorityOne() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        try analyse(rig, rig.fixture.imageID)                                              // the fixture's own picture has files
        let second = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        let added = try rig.reread.enqueueIfNeeded(now: now)
        let jobs = try queued(rig)
        #expect(added == 2 && jobs.count == 2)
        #expect(jobs.allSatisfy { $0.kind == "reread" && $0.priority == 1 && $0.state == "waiting" })
        #expect(Set(jobs.compactMap(\.imageId)) == [rig.fixture.imageID, second])
    }

    @Test func picturesThatAreGoneNotAnalysedOrAlreadyQueuedAreLeftOut() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let kept = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_100), files: false)                   // files deleted behind the app's back
        try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_200), analysed: false)                // never analysed
        let flagged = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_300))
        try rig.fixture.captures.markMissing(imageID: flagged)                                              // removed by retention
        let busy = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_400))
        try rig.jobs.enqueue(AnalysisJobRecord(kind: "analyse-force", imageId: busy, createdAt: now))      // someone asked for it already
        let added = try rig.reread.enqueueIfNeeded(now: now)
        let rereads = try queued(rig).filter { $0.kind == "reread" }.compactMap(\.imageId)
        #expect(added == 1 && rereads == [kept])
    }

    @Test func itIsDoneOnceAndTheSettingRemembersIt() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        #expect(try rig.reread.enqueueIfNeeded(now: now) == 1)
        #expect(rig.settings.int(forKey: LibraryReread.settingKey) == LibraryReread.currentVersion)
        #expect(try rig.reread.enqueueIfNeeded(now: now) == 0 && queued(rig).count == 1)
    }

    @Test func nothingIsQueuedWhenTheLibraryWasAlreadyQueuedForThisVersion() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        rig.settings.setInt(LibraryReread.currentVersion, forKey: LibraryReread.settingKey)
        #expect(try rig.reread.enqueueIfNeeded(now: now) == 0 && queued(rig).isEmpty)
        rig.settings.setInt(LibraryReread.currentVersion - 1, forKey: LibraryReread.settingKey)            // an older queueing: again
        #expect(try rig.reread.enqueueIfNeeded(now: now) == 1)
    }

    @Test func anEmptyLibraryQueuesNothingAndStillRemembersIt() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        #expect(try rig.reread.enqueueIfNeeded(now: now) == 0)
        #expect(rig.settings.int(forKey: LibraryReread.settingKey) == LibraryReread.currentVersion)
    }

    @Test func theNewestCaptureIsReadFirst() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let old = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        let newest = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_300_000))
        let middle = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_200_000))
        _ = try rig.reread.enqueueIfNeeded(now: now)
        var order: [String] = []
        while let next = try rig.jobs.nextRunnable(now: now.addingTimeInterval(100)) {
            order.append(next.imageId ?? ""); try rig.jobs.markFinished(id: next.id, now: now)
        }
        #expect(order == [newest, middle, old])
    }

    @Test func aNewCaptureQueuedLaterStillRunsBeforeTheWholeReread() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let id = try addPicture(rig, at: Date(timeIntervalSince1970: 1_800_100_000))
        _ = try rig.reread.enqueueIfNeeded(now: now)
        try rig.jobs.enqueue(AnalysisJobRecord(kind: "analyse", imageId: "new", createdAt: now.addingTimeInterval(3600)))
        #expect(try rig.jobs.nextRunnable(now: now.addingTimeInterval(7200))?.kind == "analyse")
        #expect(try rig.jobs.hasPendingAnalysis(imageID: id))
    }
}
