import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ApproveTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations {
        ItemOperations(database: fixture.database, reconciler: reconciler(fixture), now: { clock })
    }

    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id)
        let summary = await reconciler(fixture).reconcile(imageID: id)
        #expect(summary.error == nil)
        return id
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }
    private func ids(_ fixture: ReconcileFixture) throws -> [String] { try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM items ORDER BY first_seen, id") } }
    private func op(_ fixture: ReconcileFixture, _ id: OpID) throws -> OperationRecord { try #require(try OperationLog(database: fixture.database).operation(id: id)) }
    private func storedSnapshot(_ fixture: ReconcileFixture, _ id: String) throws -> [ItemField: JSONValue]? {
        ReviewRules.decode(try fixture.read { try String.fetchOne($0, sql: "SELECT approved_values_json FROM items WHERE id = ?", arguments: [id]) })
    }

    /// A doubtful item: low confidence and a guessed end.
    private func doubtful(_ fixture: ReconcileFixture) async throws -> String {
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.6, inferredEnd: true)],
                      picture: fixture.base.imageID)
        return try ids(fixture)[0]
    }

    @Test func approvingStoresTheTimeAndTheValuesAndLeavesTheInbox() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        let before = try item(fixture, id)
        #expect(before.needsReview)
        let opID = try operations(fixture).approve(id)
        let after = try item(fixture, id)
        #expect(!after.needsReview && after.reviewReasons.isEmpty && after.userTouched)
        let stored = try fixture.read { try Date.fetchOne($0, sql: "SELECT approved_at FROM items WHERE id = ?", arguments: [id]) }
        #expect(after.approvedAt == stored && stored != nil)
        let snapshot = try #require(try storedSnapshot(fixture, id))
        #expect(snapshot == ReviewRules.snapshot(of: after))
        #expect(snapshot[.title] == .string("Daily standup") && snapshot[.allDay] == .bool(false) && snapshot[.end] == .date(before.end))
        let record = try op(fixture, opID)
        #expect(record.kind == .approve && record.byUser && record.itemIDs == [id])
        #expect(record.before[id]?.approvedAt == nil)
    }

    @Test func approvingAnItemThatNeedsNoReviewIsAllowed() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.95)], picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        try operations(fixture).approve(id)
        #expect(try item(fixture, id).approvedAt != nil && item(fixture, id).needsReview == false)
    }

    @Test func aRecomputeWithNothingNewDoesNotSendAnApprovedItemBack() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        try operations(fixture).approve(id)
        try fixture.write { try ItemStore.recompute($0, itemID: id, at: Date(timeIntervalSince1970: 1_800_300_000)) }
        #expect(try item(fixture, id).needsReview == false)
        _ = await reconciler(fixture).reconcile(imageID: fixture.base.imageID)
        #expect(try item(fixture, id).needsReview == false)
    }

    @Test func approvingADismissedOrMergedItemIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        let ops = operations(fixture)
        try ops.dismiss(id)
        #expect(throws: ItemOperationError.wrongStatus) { try ops.approve(id) }
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "gone"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "UPDATE items SET status = 'merged', merged_into = ? WHERE id = 'gone'", arguments: [id])
        }
        #expect(throws: ItemOperationError.merged) { try ops.approve("gone") }
        #expect(throws: ItemOperationError.notFound) { try ops.approve("nobody") }
        #expect(try fixture.count("reconcile_ops") == 1)
    }

    @Test func undoingAnApprovalRestoresTheInboxStateExactly() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        let before = try fixture.snapshot()
        let approve = try operations(fixture).approve(id)
        #expect(try fixture.snapshot() != before)
        _ = try await operations(fixture).undo(approve)
        #expect(ReconcileFixture.difference(try fixture.snapshot(), before) == "")
        #expect(try item(fixture, id).approvedAt == nil && item(fixture, id).reviewReasons == [.lowConfidence, .guessedEnd])
        #expect(try storedSnapshot(fixture, id) == nil)
    }

    @Test func undoingASecondApprovalRestoresTheFirstOne() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        let ops = operations(fixture)
        try ops.approve(id)
        let afterFirst = try fixture.snapshot()
        let second = try ops.approve(id)
        #expect(try op(fixture, second).before[id]?.approvedAt != nil)
        _ = try await ops.undo(second)
        #expect(ReconcileFixture.difference(try fixture.snapshot(), afterFirst) == "")
        #expect(try item(fixture, id).needsReview == false)
    }

    // MARK: later sightings

    @Test func aLaterSightingThatChangesAnUnlockedApprovedValueReturnsTheItemToTheInbox() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        try operations(fixture).approve(id)
        #expect(try item(fixture, id).end == nil)
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(45), confidence: 0.9)])
        #expect(try ids(fixture) == [id])
        let after = try item(fixture, id)
        #expect(after.end == ReconcileFixture.minutes(45))                      // unlocked values still update
        #expect(after.needsReview && after.reviewReasons == [.changedAfterApproval])
        #expect(after.approvedAt != nil)                                        // the approval history is kept
        // approving again takes it out of the Inbox
        try operations(fixture).approve(id)
        #expect(try item(fixture, id).needsReview == false)
    }

    @Test func aLaterSightingDoesNotChangeALockedFieldOrBringTheItemBack() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        let ops = operations(fixture)
        try ops.edit(id, field: .end, value: .date(ReconcileFixture.minutes(30)))
        try ops.approve(id)
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(45), confidence: 0.9)])
        let after = try item(fixture, id)
        #expect(after.end == ReconcileFixture.minutes(30) && !after.needsReview)
    }

    @Test func aLaterSightingWithTheSameValuesLeavesAnApprovedItemApproved() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        try operations(fixture).approve(id)
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.5, inferredEnd: true)])
        #expect(try ids(fixture) == [id])
        #expect(try item(fixture, id).needsReview == false)
    }

    // MARK: merge and split

    private func twoApprovable(_ fixture: ReconcileFixture) async throws -> (a: String, b: String) {
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Reunión diaria")])
        let all = try ids(fixture)
        return (all[0], all[1])
    }

    @Test func mergingTwoApprovedItemsKeepsTheApproval() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoApprovable(fixture)
        let ops = operations(fixture)
        try ops.approve(a); try ops.approve(b)
        try ops.merge(a, b)
        let merged = try item(fixture, a)
        #expect(merged.approvedAt != nil && merged.needsReview == false)
        #expect(try storedSnapshot(fixture, a) != nil)
    }

    @Test func mergingAnApprovedItemWithAnUnapprovedOneClearsTheApproval() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoApprovable(fixture)
        let ops = operations(fixture)
        try ops.approve(a)
        let before = try fixture.snapshot()
        let merge = try ops.merge(a, b)
        let merged = try item(fixture, a)
        #expect(merged.approvedAt == nil)
        #expect(try storedSnapshot(fixture, a) == nil)
        _ = try await ops.undo(merge)
        #expect(ReconcileFixture.difference(try fixture.snapshot(), before) == "")
        #expect(try item(fixture, a).approvedAt != nil)
    }

    @Test func aSplitOffItemIsNotApproved() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9)], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9)])
        let id = try ids(fixture)[0]
        try operations(fixture).approve(id)
        let sightings = try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM sightings WHERE item_id = ?", arguments: [id]) }
        let (_, made) = try operations(fixture).split(id, sightings: [sightings[0]])
        #expect(try item(fixture, made).approvedAt == nil)
        #expect(try storedSnapshot(fixture, made) == nil)
        #expect(try item(fixture, id).approvedAt != nil)
    }

    // MARK: the log

    @Test func operationsWrittenBeforeApprovalsExistedStillDecodeAndUndo() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await doubtful(fixture)
        let edit = try operations(fixture).edit(id, field: .place, value: .string("Room 4"))
        // The before-state of an old entry has no approval fields at all.
        try fixture.write { db in
            let old = #"{"\#(id)":{"status":"active","mergedInto":null,"userTouched":false,"locks":{},"observations":[]}}"#
            try db.execute(sql: "UPDATE reconcile_ops SET before_json = ? WHERE id = ?", arguments: [old, edit])
        }
        let record = try op(fixture, edit)
        #expect(record.before[id]?.approvedAt == nil && record.before[id]?.approvedValues == nil)
        let result = try await operations(fixture).undo(edit)
        if case .undone = result {} else { Issue.record("expected the undo to work, got \(result)") }
        #expect(try item(fixture, id).place == nil)
    }
}
