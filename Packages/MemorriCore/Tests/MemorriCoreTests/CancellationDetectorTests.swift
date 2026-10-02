import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// A meeting two later captures of its calendar dates leave out becomes `Possibly cancelled`; nothing else is touched (spec 010, US1).
@Suite struct CancellationDetectorTests {
    private let clock = Date(timeIntervalSince1970: 1_800_100_000)
    private let day: TimeInterval = 86_400

    private func reconciler(_ f: ReconcileFixture) -> Reconciler { Reconciler(database: f.database, judge: NoMeaningJudge(), now: { clock }) }
    private func detector(_ f: ReconcileFixture) -> CancellationDetector { CancellationDetector(database: f.database, now: { clock }) }

    /// The 08:00 to 14:00 stretch of the sample day (the appointments are at 07:00 UTC + minutes).
    private func view(window: String = "w0", from: Int = -120, to: Int = 600) -> CoverageDraft {
        CoverageDraft(windowKey: window, kind: .calendarWeek, spans: [DateInterval(start: ReconcileFixture.minutes(from), end: ReconcileFixture.minutes(to))])
    }

    /// A new capture `days` after the sample day showing `titles` (appointments at 07:00 + 60 minutes), with a context and coverage.
    @discardableResult
    private func capture(_ f: ReconcileFixture, days: Double, titles: [String], context: String? = "ctx-a", coverage: [CoverageDraft]? = nil, record: Bool = true,
                         starts: [String: Int] = [:]) async throws -> (image: String, flagged: [String]) {
        let image = try f.addPicture(at: ReconcileFixture.nine.addingTimeInterval(days * day))
        try f.save(titles.map { f.finding($0, start: ReconcileFixture.minutes(starts[$0] ?? 60), end: ReconcileFixture.minutes((starts[$0] ?? 60) + 30)) },
                   imageID: image, contextID: context)
        _ = await reconciler(f).reconcile(imageID: image)
        let flagged = record ? try detector(f).record(imageID: image, coverage: coverage ?? [view()]) : []
        return (image, flagged)
    }

    private func item(_ f: ReconcileFixture, _ title: String) throws -> Item {
        let id = try #require(try f.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = ?", arguments: [title]) })
        return try #require(try ItemStore(database: f.database).item(id: id))
    }

    // Non-throwing readers for use inside `#expect` (a `try` cannot sit in the middle of an expression).
    private func reasons(_ f: ReconcileFixture, _ title: String) -> [ReviewReason] { (try? item(f, title).reviewReasons) ?? [.lowConfidence] }
    private func needsReview(_ f: ReconcileFixture, _ title: String) -> Bool { (try? item(f, title).needsReview) ?? false }
    private func rows(_ f: ReconcileFixture, _ table: String) -> Int { (try? f.count(table)) ?? -1 }

    private func fixture() throws -> ReconcileFixture {
        let f = try ReconcileFixture()
        try f.addContext("ctx-a", "Customer A"); try f.addContext("ctx-b", "Customer B")
        return f
    }

    @Test func twoCoveringCapturesWithoutTheMeetingFlagItAndOneDoesNot() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        let one = try await capture(f, days: 1, titles: ["Budget review"])
        #expect(one.flagged.isEmpty && reasons(f, "Standup").isEmpty)
        #expect(rows(f, "cancel_absences") == 1 && rows(f, "calendar_coverage") == 2)
        let two = try await capture(f, days: 2, titles: ["Budget review"])
        let standup = try item(f, "Standup")
        #expect(two.flagged == [standup.id] && standup.reviewReasons == [.possiblyCancelled] && standup.needsReview)
        #expect(reasons(f, "Budget review").isEmpty)
    }

    @Test func aLaterSightingClearsTheFlagAndTheAbsences() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        try await capture(f, days: 1, titles: ["Budget review"]); try await capture(f, days: 2, titles: ["Budget review"])
        #expect(needsReview(f, "Standup"))
        try await capture(f, days: 3, titles: ["Standup", "Budget review"])
        let standup = try item(f, "Standup")
        #expect(!standup.needsReview && standup.reviewReasons.isEmpty && rows(f, "cancel_absences") == 0)
    }

    @Test func capturesThatProveNothingAddNoAbsence() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        // Another context, no context, another day, and no coverage at all.
        try await capture(f, days: 1, titles: ["Budget review"], context: "ctx-b")
        try await capture(f, days: 2, titles: ["Budget review"], context: nil)
        try await capture(f, days: 3, titles: ["Budget review"], coverage: [CoverageDraft(windowKey: "w0", kind: .calendarWeek,
                                                                                         spans: [DateInterval(start: ReconcileFixture.minutes(24 * 60), end: ReconcileFixture.minutes(30 * 60))])])
        try await capture(f, days: 4, titles: ["Budget review"], coverage: [])
        #expect(rows(f, "cancel_absences") == 0 && reasons(f, "Standup").isEmpty)
        #expect(rows(f, "calendar_coverage") == 3)                                                         // the capture with no context stored none
    }

    @Test func anAllDayItemAndAnItemSeenOnlyOutsideCalendarViewsAreNeverFlagged() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        // "Holiday" is seen once on a screen with no coverage (a mail window), "Review" is all-day.
        try await capture(f, days: 0, titles: ["Holiday"], coverage: [], starts: ["Holiday": 60])
        let image = try f.addPicture(at: ReconcileFixture.nine.addingTimeInterval(day * 0.5))
        try f.save([f.finding("Review", start: ReconcileFixture.minutes(0), allDay: true)], imageID: image, contextID: "ctx-a")
        _ = await reconciler(f).reconcile(imageID: image)
        _ = try detector(f).record(imageID: image, coverage: [view()])
        try await capture(f, days: 1, titles: ["Other"], starts: ["Other": 400]); try await capture(f, days: 2, titles: ["Other"], starts: ["Other": 400])
        #expect(reasons(f, "Holiday").isEmpty && reasons(f, "Review").isEmpty)
        #expect(rows(f, "cancel_absences") == 0)
    }

    @Test func reanalysisAndRereadAddNoAbsenceAndDropOnesTheirSightingsContradict() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        let second = try await capture(f, days: 1, titles: ["Budget review"])
        #expect(rows(f, "cancel_absences") == 1)
        // The capture is read again and now shows the meeting: its absence goes; a reanalysis that still omits it adds none.
        try f.save([f.finding("Budget review", start: ReconcileFixture.minutes(60), end: ReconcileFixture.minutes(90)),
                    f.finding("Standup", start: ReconcileFixture.minutes(60), end: ReconcileFixture.minutes(90))], imageID: second.image, contextID: "ctx-a")
        _ = await reconciler(f).reconcile(imageID: second.image)
        try detector(f).clearContradicted(imageID: second.image)
        #expect(rows(f, "cancel_absences") == 0)
        try f.save([f.finding("Budget review")], imageID: second.image, contextID: "ctx-a")
        _ = await reconciler(f).reconcile(imageID: second.image)
        try detector(f).clearContradicted(imageID: second.image)
        #expect(rows(f, "cancel_absences") == 0)                                                           // no `record` on this path: nothing new
    }

    @Test func aCaptureWhoseContextWasChangedLaterIsJudgedByItsCurrentContext() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        try await capture(f, days: 1, titles: ["Budget review"])
        let third = try await capture(f, days: 2, titles: ["Budget review"], record: false)
        try f.write { try $0.execute(sql: "UPDATE image_context SET context_id = 'ctx-b' WHERE image_id = ?", arguments: [third.image]) }
        let flagged = try detector(f).record(imageID: third.image, coverage: [view()])
        #expect(flagged.isEmpty && rows(f, "cancel_absences") == 1)
    }

    @Test func deletingTheCapturesTakesTheSuspicionWithThem() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        let b = try await capture(f, days: 1, titles: ["Budget review"]); let c = try await capture(f, days: 2, titles: ["Budget review"])
        let standup = try item(f, "Standup")
        #expect(standup.needsReview)
        let events = try f.read { try String.fetchAll($0, sql: "SELECT event_id FROM capture_images WHERE id IN (?, ?)", arguments: [b.image, c.image]) }
        try f.base.captures.deleteEvents(ids: events)
        _ = try f.write { try ItemStore.recompute($0, itemID: standup.id, at: clock) }
        #expect(rows(f, "cancel_absences") == 0 && reasons(f, "Standup").isEmpty)
    }
}
