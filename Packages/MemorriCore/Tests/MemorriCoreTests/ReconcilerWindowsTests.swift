import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Findings of one picture that sit in different windows (spec 011, research R7): the rule that keeps two uncertain findings of one picture apart
/// (`same-picture-different`) applies within one window only.
@Suite struct ReconcilerWindowsTests {
    private func reconciler(_ fixture: ReconcileFixture, judge: any MeaningJudging) -> Reconciler {
        Reconciler(database: fixture.database, judge: judge, now: { Date(timeIntervalSince1970: 1_791_999_000) })
    }

    private func finding(_ fixture: ReconcileFixture, _ title: String, window: String?) -> Finding {
        let base = fixture.finding(title)
        return Finding(id: base.id, kind: base.kind, title: base.title, allDay: base.allDay, start: base.start, end: base.end, timezone: base.timezone,
                       citedLines: base.citedLines, confidence: base.confidence, provenance: base.provenance, windowKey: window)
    }

    private func items(_ fixture: ReconcileFixture) throws -> [Item] {
        try ItemStore(database: fixture.database).items(status: [.active, .dismissed, .merged], kinds: nil, contextID: nil).map(\.item)
    }

    private func sightings(_ fixture: ReconcileFixture, item: String) throws -> Int {
        try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sightings WHERE item_id = ?", arguments: [item]) ?? 0 }
    }

    private func reconcile(_ findings: [Finding], judge: FakeMeaningJudge) async throws -> ReconcileFixture {
        let fixture = try ReconcileFixture()
        try fixture.save(findings)
        _ = await reconciler(fixture, judge: judge).reconcile(imageID: fixture.base.imageID)
        return fixture
    }

    @Test func twoFindingsThatLookTheSameInDifferentWindowsAreOneItemWithTwoSightings() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Sprint review", window: "w0"), finding(probe, "Sprint retrospective", window: "w1")], judge: judge)
        defer { fixture.cleanUp() }
        let all = try items(fixture)
        #expect(all.count == 1)
        #expect(try sightings(fixture, item: all[0].id) == 2)
        #expect(judge.judgeCalls.count == 1)                     // the judge was asked, and said yes
    }

    @Test func twoSuchFindingsInTheSameWindowStayApartWithoutAskingTheJudge() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Sprint review", window: "w0"), finding(probe, "Sprint retrospective", window: "w0")], judge: judge)
        defer { fixture.cleanUp() }
        #expect(try items(fixture).count == 2)
        #expect(judge.judgeCalls.isEmpty)
        #expect(try fixture.count("possible_duplicates") == 0)
    }

    @Test func olderFindingsWithNoWindowKeyBehaveAsBefore() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Sprint review", window: nil), finding(probe, "Sprint retrospective", window: nil)], judge: judge)
        defer { fixture.cleanUp() }
        #expect(try items(fixture).count == 2)
        #expect(judge.judgeCalls.isEmpty)
    }

    @Test func aFindingWithAKeyAndOneWithoutAreNotTheSameWindow() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Sprint review", window: "w0"), finding(probe, "Sprint retrospective", window: nil)], judge: judge)
        defer { fixture.cleanUp() }
        #expect(try items(fixture).count == 1 && judge.judgeCalls.count == 1)
    }

    @Test func identicalTitlesInDifferentWindowsMergeByTextWithoutTheJudge() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 0)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Daily standup", window: "w0"), finding(probe, "Daily standup", window: "w1")], judge: judge)
        defer { fixture.cleanUp() }
        let all = try items(fixture)
        #expect(all.count == 1 && judge.judgeCalls.isEmpty)
        #expect(try sightings(fixture, item: all[0].id) == 2)
    }

    @Test func reconcilingAgainKeepsTheSameItemsAndSightings() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let probe = try ReconcileFixture(); defer { probe.cleanUp() }
        let fixture = try await reconcile([finding(probe, "Sprint review", window: "w0"), finding(probe, "Sprint retrospective", window: "w1")], judge: judge)
        defer { fixture.cleanUp() }
        _ = await reconciler(fixture, judge: judge).reconcile(imageID: fixture.base.imageID)
        let all = try items(fixture)
        #expect(all.count == 1)
        #expect(try sightings(fixture, item: all[0].id) == 2)
    }

    @Test func aSightingCopiesTheApplicationAndTitleOfItsFindingsWindow() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let reading = WindowReadingRecord(imageID: fixture.base.imageID, windowKey: "w1", appName: "Calendar", title: "Work week", frame: PixelBox(x: 0, y: 0, width: 10, height: 10),
                                          visible: [], visibleShare: 1, relevant: true, kind: .calendarWeek, confidence: 0.9, remote: false, runID: nil,
                                          promptVersion: "windows-v1", createdAt: Date(timeIntervalSince1970: 1_791_950_000))
        try fixture.save([finding(fixture, "Sprint review", window: "w1"), finding(fixture, "Dentist", window: nil)])
        try WindowReadingStore(database: fixture.database).save(imageID: fixture.base.imageID, readings: [reading])      // saving an analysis replaces them
        _ = await reconciler(fixture, judge: FakeMeaningJudge(defaultAnswer: 0)).reconcile(imageID: fixture.base.imageID)
        let rows = try fixture.read { try Row.fetchAll($0, sql: "SELECT title, window_app, window_title FROM sightings ORDER BY title") }
        #expect(rows.count == 2)
        #expect(rows[0]["title"] as String == "Dentist" && rows[0]["window_app"] as String? == nil && rows[0]["window_title"] as String? == nil)
        #expect(rows[1]["window_app"] as String? == "Calendar" && rows[1]["window_title"] as String? == "Work week")
    }

    // MARK: a window capture beside a full-screen capture (spec 013, FR-017)

    @Test func theSameEventSeenInAWindowCaptureAndInAFullScreenCaptureIsOneItemWithTwoSightings() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let window = try fixture.addPicture(at: ReconcileFixture.minutes(30))
        try fixture.write { db in
            try db.execute(sql: "UPDATE capture_events SET scope = 'window' WHERE id = (SELECT event_id FROM capture_images WHERE id = ?)", arguments: [window])
        }
        #expect(try CaptureStore(database: fixture.base.database).scope(imageID: window) == .window)
        try fixture.save([finding(fixture, "Sprint review", window: nil)])                                  // the full-screen capture
        try fixture.save([finding(fixture, "Sprint review", window: "w0")], imageID: window)              // the window capture
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let reconciler = reconciler(fixture, judge: judge)
        _ = await reconciler.reconcile(imageID: fixture.base.imageID)
        _ = await reconciler.reconcile(imageID: window)
        let all = try items(fixture)
        #expect(all.count == 1)
        #expect(try sightings(fixture, item: all[0].id) == 2)
    }
}
