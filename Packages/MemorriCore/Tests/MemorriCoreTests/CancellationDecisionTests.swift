import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// The user's two answers to a possibly cancelled item (spec 010 FR-005): `Cancelled` is Dismiss, `Still happening` approves and waits to see it again.
@Suite struct CancellationDecisionTests {
    private let clock = Date(timeIntervalSince1970: 1_800_100_000)
    private let day: TimeInterval = 86_400
    /// The user decides between the captures of day 2 and day 3.
    private var decided: Date { ReconcileFixture.nine.addingTimeInterval(2.5 * day) }

    private struct Rig { let f: ReconcileFixture; let ops: ItemOperations; let id: String }

    private func view() -> CoverageDraft {
        CoverageDraft(windowKey: "w0", kind: .calendarWeek, spans: [DateInterval(start: ReconcileFixture.minutes(-120), end: ReconcileFixture.minutes(600))])
    }

    @discardableResult
    private func capture(_ f: ReconcileFixture, days: Double, titles: [String]) async throws -> String {
        let image = try f.addPicture(at: ReconcileFixture.nine.addingTimeInterval(days * day))
        try f.save(titles.map { f.finding($0, start: ReconcileFixture.minutes(60), end: ReconcileFixture.minutes(90)) }, imageID: image, contextID: "ctx-a")
        _ = await Reconciler(database: f.database, judge: NoMeaningJudge(), now: { clock }).reconcile(imageID: image)
        _ = try CancellationDetector(database: f.database, now: { clock }).record(imageID: image, coverage: [view()])
        return image
    }

    /// "Standup" was shown on day 0 and left out of days 1 and 2 (flagged); "Budget review" is on every capture.
    private func flagged() async throws -> Rig {
        let f = try ReconcileFixture()
        try f.addContext("ctx-a", "Customer A")
        // Two meetings at the same time would look like a possible duplicate; give the second one its own slot by title only (judge is off).
        try await capture(f, days: 0, titles: ["Standup", "Budget review"])
        try await capture(f, days: 1, titles: ["Budget review"]); try await capture(f, days: 2, titles: ["Budget review"])
        let id = try #require(try f.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = 'Standup'") })
        return Rig(f: f, ops: ItemOperations(database: f.database, now: { decided }), id: id)
    }

    private func item(_ rig: Rig) -> Item? { try? ItemStore(database: rig.f.database).item(id: rig.id) }
    private func absences(_ rig: Rig) -> Int { (try? rig.f.count("cancel_absences")) ?? -1 }
    private func reasons(_ rig: Rig) -> [ReviewReason] { item(rig)?.reviewReasons ?? [] }

    @Test func stillHappeningApprovesDropsTheAbsencesAndWaitsToSeeTheMeetingAgain() async throws {
        let rig = try await flagged(); defer { rig.f.cleanUp() }
        #expect(reasons(rig).contains(.possiblyCancelled))
        let op = try rig.ops.confirmStillHappening(rig.id)
        #expect(item(rig)?.approvedAt != nil && !(reasons(rig).contains(.possiblyCancelled)) && absences(rig) == 0)
        #expect(try OperationLog(database: rig.f.database).operation(id: op)?.kind == .stillHappening)
        // Left out of two more captures without being seen in between: not flagged again.
        try await capture(rig.f, days: 3, titles: ["Budget review"]); try await capture(rig.f, days: 4, titles: ["Budget review"])
        #expect(!(reasons(rig).contains(.possiblyCancelled)))
        // Seen again, then missing twice: flagged again.
        try await capture(rig.f, days: 5, titles: ["Standup", "Budget review"])
        try await capture(rig.f, days: 6, titles: ["Budget review"]); try await capture(rig.f, days: 7, titles: ["Budget review"])
        #expect(reasons(rig).contains(.possiblyCancelled))
    }

    @Test func approveOnAFlaggedItemIsTheSameAsStillHappening() async throws {
        let rig = try await flagged(); defer { rig.f.cleanUp() }
        let op = try rig.ops.approve(rig.id)
        #expect(try OperationLog(database: rig.f.database).operation(id: op)?.kind == .stillHappening)
        #expect(!(reasons(rig).contains(.possiblyCancelled)) && absences(rig) == 0)
    }

    @Test func stillHappeningOnAnItemThatIsNotFlaggedIsRefused() async throws {
        let rig = try await flagged(); defer { rig.f.cleanUp() }
        let other = try #require(try rig.f.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = 'Budget review'") })
        #expect(throws: ItemOperationError.self) { try rig.ops.confirmStillHappening(other) }
    }

    @Test func undoPutsTheSuspicionAndTheAbsencesBack() async throws {
        let rig = try await flagged(); defer { rig.f.cleanUp() }
        let before = try rig.f.snapshot()
        let op = try rig.ops.confirmStillHappening(rig.id)
        let result = try await rig.ops.undo(op)
        guard case .undone = result else { Issue.record("expected the undo to work, got \(result)"); return }
        #expect(reasons(rig).contains(.possiblyCancelled) && absences(rig) == 2 && item(rig)?.approvedAt == nil)
        let clearedAt = try rig.f.read { try Date.fetchOne($0, sql: "SELECT cancel_cleared_at FROM items WHERE id = ?", arguments: [rig.id]) }
        #expect(clearedAt == nil)
        let after = try rig.f.snapshot()
        #expect(before == after, "\(ReconcileFixture.difference(before, after))")
    }

    @Test func cancelledIsDismissAndItsUndoBringsTheSuspicionBack() async throws {
        let rig = try await flagged(); defer { rig.f.cleanUp() }
        let op = try rig.ops.dismiss(rig.id)
        #expect(item(rig)?.status == .dismissed && reasons(rig).isEmpty && absences(rig) == 2)          // nothing but the status changed
        _ = try await rig.ops.undo(op)
        #expect(item(rig)?.status == .active && reasons(rig).contains(.possiblyCancelled))
    }
}
