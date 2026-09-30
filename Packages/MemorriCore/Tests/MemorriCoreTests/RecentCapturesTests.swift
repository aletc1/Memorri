import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct RecentCapturesTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let fixture: PipelineFixture
        let overview: CaptureOverview
        let jobs: AnalysisStore
        let results: AnalysisResultStore
    }

    private func makeRig() throws -> Rig {
        let fixture = try makePipelineFixture()
        return Rig(fixture: fixture, overview: CaptureOverview(database: fixture.database), jobs: AnalysisStore(database: fixture.database),
                   results: AnalysisResultStore(database: fixture.database))
    }

    private func addCapture(_ rig: Rig, id: String, at seconds: TimeInterval, displays: Int = 1) throws -> [String] {
        let event = makeEventRecord(id: "e-\(id)", at: t0.addingTimeInterval(seconds), displayCount: displays)
        let images = (1...displays).map { makeImageRecord(eventID: event.id, id: "\(id)-\($0)", displayID: $0) }
        try CaptureStore(database: rig.fixture.database).insert(event: event, images: images)
        return images.map(\.id)
    }

    private func analyse(_ rig: Rig, _ imageID: String, findings: [Finding] = [], kind: ScreenKind = .calendarWeek) throws {
        let classification = ClassificationResult(kind: kind, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "",
                                                  theme: "", calendarName: "")
        try rig.results.save(AnalysisResult(lines: [], classification: classification, tags: [CaptureTag(key: "theme", value: "light", confidence: 1, source: "visual")],
                                            findings: findings, timezone: TimeZone(identifier: "UTC")!),
                             imageID: imageID, runID: nil, at: t0)
    }

    private func job(_ rig: Rig, _ imageID: String, state: AnalysisJobRecord.State, reason: String? = nil, at seconds: TimeInterval = 0) throws {
        let record = AnalysisJobRecord(kind: "analyse", imageId: imageID, state: state, failureReason: reason, createdAt: t0.addingTimeInterval(seconds))
        try rig.jobs.enqueue(record)
    }

    @Test func picturesComeNewestFirstWithTheDisplaysOfOneCaptureTogether() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try addCapture(rig, id: "old", at: 10)
        _ = try addCapture(rig, id: "new", at: 100, displays: 3)
        let recent = try rig.overview.recent(limit: 20).filter { $0.id != rig.fixture.imageID }
        #expect(recent.map(\.id) == ["new-1", "new-2", "new-3", "old-1"])
        #expect(recent[0].displayCount == 3 && recent[3].displayCount == 1)
        #expect(recent[0].capturedAt == t0.addingTimeInterval(100))
    }

    @Test func theLimitCountsPictures() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        for i in 0..<25 { _ = try addCapture(rig, id: "c\(i)", at: Double(i)) }
        #expect(try rig.overview.recent(limit: 20).count == 20)
        #expect(try rig.overview.recent(limit: 3).count == 3)
    }

    @Test func theStateComesFromTheAnalysisAndTheJob() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let ids = ["none", "waiting", "running", "done", "failed"]
        for (i, id) in ids.enumerated() { _ = try addCapture(rig, id: id, at: Double(i)) }
        try job(rig, "waiting-1", state: .waiting)
        try job(rig, "running-1", state: .running)
        try analyse(rig, "done-1")
        try job(rig, "failed-1", state: .failed, reason: "timed out")
        let states = Dictionary(uniqueKeysWithValues: try rig.overview.recent(limit: 20).map { ($0.id, $0.state) })
        #expect(states["none-1"] == .notAnalysed)
        #expect(states["waiting-1"] == .waiting)
        #expect(states["running-1"] == .analysing)
        #expect(states["done-1"] == .analysed)
        #expect(states["failed-1"] == .failed("timed out"))
    }

    @Test func anAnalysedPictureWithAFailedReanalysisStaysAnalysed() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try addCapture(rig, id: "a", at: 1)
        try analyse(rig, "a-1")
        try job(rig, "a-1", state: .failed, reason: "timed out")
        #expect(try rig.overview.recent(limit: 5).first { $0.id == "a-1" }?.state == .analysed)
    }

    @Test func anAnalysedPictureShowsItsKindCountFindingsAndTags() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try addCapture(rig, id: "a", at: 1)
        let findings = [Finding(kind: .task, title: "Send report", allDay: true, timezone: "UTC", citedLines: [1], confidence: 0.9, unresolved: ["due": "Friday"]),
                        Finding(kind: .appointment, title: "Sync", allDay: false, timezone: "UTC", citedLines: [2], confidence: 0.9)]
        try analyse(rig, "a-1", findings: findings, kind: .email)
        let row = try #require(try rig.overview.recent(limit: 5).first { $0.id == "a-1" })
        #expect(row.kind == .email && row.findingCount == 2)
        #expect(Set(row.findings.map(\.title)) == ["Send report", "Sync"])
        #expect(row.tags.map(\.key) == ["theme"])
        #expect(row.contextName == nil && row.contextChosenByUser == false)
    }

    @Test func theContextShowsWhoChoseIt() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try addCapture(rig, id: "a", at: 1)
        try rig.fixture.database.pool.write { db in
            try db.execute(sql: "INSERT INTO contexts (id, name, created_at, updated_at) VALUES ('c1', 'Customer A', ?, ?)", arguments: [t0, t0])
            try db.execute(sql: "INSERT INTO image_context (image_id, context_id, source, score, decided_at) VALUES ('a-1', 'c1', 'user', 0, ?)", arguments: [t0])
        }
        let row = try #require(try rig.overview.recent(limit: 5).first { $0.id == "a-1" })
        #expect(row.contextName == "Customer A" && row.contextChosenByUser)
    }

    @Test func aPictureWhoseFileIsGoneIsStillListed() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try addCapture(rig, id: "a", at: 1)
        try rig.fixture.captures.markMissing(imageID: "a-1")
        #expect(try rig.overview.recent(limit: 5).contains { $0.id == "a-1" })
    }
}
