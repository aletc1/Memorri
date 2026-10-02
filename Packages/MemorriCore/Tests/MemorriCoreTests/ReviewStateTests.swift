import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// What the Inbox lists is stored on each item and kept right by every change (spec 006, US2, FR-010 to FR-017).
@Suite struct ReviewStateTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations {
        ItemOperations(database: fixture.database, reconciler: reconciler(fixture), now: { clock })
    }

    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil, context: String? = nil) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id, contextID: context)
        let summary = await reconciler(fixture).reconcile(imageID: id)
        #expect(summary.error == nil)
        return id
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }
    private func ids(_ fixture: ReconcileFixture) throws -> [String] { try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM items ORDER BY first_seen, id") } }

    /// Two items for one event: the translated title could not be judged, so it stayed apart as a possible duplicate.
    private func twoItems(_ fixture: ReconcileFixture) async throws -> (a: String, b: String) {
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Reunión diaria")])
        let all = try ids(fixture)
        return (all[0], all[1])
    }

    // MARK: after reconciliation

    @Test func aGuessedEndPutsAConfidentItemInTheInbox() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9, inferredEnd: true)],
                      picture: fixture.base.imageID)
        let only = try item(fixture, try ids(fixture)[0])
        #expect(only.needsReview && only.reviewReasons == [.guessedEnd])
    }

    @Test func aClearlyReadConfidentItemNeedsNoReview() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9)], picture: fixture.base.imageID)
        let only = try item(fixture, try ids(fixture)[0])
        #expect(!only.needsReview && only.reviewReasons.isEmpty && only.approvedAt == nil)
    }

    @Test func aFaintItemNeedsReviewForItsConfidence() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID)
        #expect(try item(fixture, try ids(fixture)[0]).reviewReasons == [.lowConfidence])
    }

    @Test func aLaterBetterSightingTakesTheDoubtAway() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.6, inferredEnd: true)],
                      picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        #expect(try item(fixture, id).reviewReasons == [.lowConfidence, .guessedEnd])
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.95)])
        #expect(try ids(fixture) == [id])
        #expect(try item(fixture, id).needsReview == false)
    }

    // MARK: the count

    @Test func theCountIsTheNumberOfRowsNeedingReviewAndFollowsTheContext() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("work", "Work")
        try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID, context: "work")
        try await see(fixture, [fixture.finding("Lunch with Sam", start: ReconcileFixture.minutes(240), confidence: 0.6)])
        try await see(fixture, [fixture.finding("Dentist", start: ReconcileFixture.minutes(480), confidence: 0.95)])
        let store = ItemStore(database: fixture.database)
        let listed = try store.items(status: [.active, .dismissed, .merged], kinds: nil, contextID: nil).filter { $0.item.needsReview }.count
        #expect(listed == 2)
        #expect(try store.reviewCount() == 2)
        #expect(try store.reviewCount(contextID: .some("work")) == 1)
        #expect(try store.reviewCount(contextID: .some(nil)) == 1)
        #expect(try store.reviewCount(contextID: .some("other")) == 0)
    }

    @Test func theCountCanBeObserved() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID)
        var iterator = ItemStore(database: fixture.database).observeReviewCount().makeAsyncIterator()
        #expect(await iterator.next() == 1)
        try operations(fixture).approve(try ids(fixture)[0])
        #expect(await iterator.next() == 0)
    }

    // MARK: kept right by every change

    @Test func dismissingAndRestoringMoveAnItemOutOfAndBackIntoTheInbox() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        let ops = operations(fixture)
        let dismiss = try ops.dismiss(id)
        #expect(try item(fixture, id).needsReview == false && ItemStore(database: fixture.database).reviewCount() == 0)
        try ops.restore(id)
        #expect(try item(fixture, id).needsReview && ItemStore(database: fixture.database).reviewCount() == 1)
        _ = dismiss
    }

    @Test func lockingAGuessedTimeSettlesItAndUnlockingBringsTheDoubtBack() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9, inferredEnd: true)],
                      picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        let ops = operations(fixture)
        try ops.edit(id, field: .end, value: .date(ReconcileFixture.minutes(30)))
        #expect(try item(fixture, id).reviewReasons.contains(.guessedEnd) == false)
        try ops.unlock(id, field: .end)
        #expect(try item(fixture, id).needsReview)
    }

    @Test func aPossibleDuplicateFlagsBothItemsUntilDecided() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        #expect(try fixture.count("possible_duplicates") == 1)
        #expect(try item(fixture, a).reviewReasons == [.possibleDuplicate] && item(fixture, b).reviewReasons == [.possibleDuplicate])
        let different = try operations(fixture).markDifferent(a, b)
        #expect(try item(fixture, a).needsReview == false && item(fixture, b).needsReview == false)
        _ = try await operations(fixture).undo(different)
        #expect(try item(fixture, a).reviewReasons == [.possibleDuplicate] && item(fixture, b).reviewReasons == [.possibleDuplicate])
    }

    @Test func mergingTheDuplicateEndsTheDoubtForTheSurvivorAndTheMergedItemNeverNeedsReview() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let before = try fixture.snapshot()
        let merge = try operations(fixture).merge(a, b)
        #expect(try item(fixture, a).needsReview == false)
        let gone = try item(fixture, b)
        #expect(gone.status == .merged && gone.needsReview == false && gone.reviewReasons.isEmpty)
        #expect(try ItemStore(database: fixture.database).reviewCount() == 0)
        _ = try await operations(fixture).undo(merge)
        #expect(ReconcileFixture.difference(try fixture.snapshot(), before) == "")
        #expect(try ItemStore(database: fixture.database).reviewCount() == 2)
    }

    @Test func mergingAnItemAwayEndsTheDoubtOfItsOtherPartners() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try await see(fixture, [fixture.finding("Tägliches Treffen")])
        let all = try ids(fixture)
        let c = try #require(all.first { $0 != a && $0 != b })
        // c is a possible duplicate of at least one of the two; merging b into a leaves c flagged only if a row still names a live partner.
        try operations(fixture).merge(a, b)
        let rows = try fixture.read { try Row.fetchAll($0, sql: "SELECT item_a, item_b FROM possible_duplicates") }
        let stillNamed = rows.contains { ($0["item_a"] as String) == c || ($0["item_b"] as String) == c }
        #expect(try item(fixture, c).reviewReasons.contains(.possibleDuplicate) == stillNamed)
        #expect(try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil).filter(\.item.needsReview).count
                == ItemStore(database: fixture.database).reviewCount())
    }

    @Test func splittingGivesTheNewItemItsOwnState() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.9)], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.6)])
        let id = try ids(fixture)[0]
        #expect(try item(fixture, id).needsReview == false)
        let sightings = try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM sightings WHERE item_id = ? ORDER BY confidence", arguments: [id]) }
        let (_, made) = try operations(fixture).split(id, sightings: [sightings[0]])
        #expect(try item(fixture, made).reviewReasons == [.lowConfidence] && item(fixture, made).approvedAt == nil)
        #expect(try item(fixture, id).needsReview == false)
    }

    @Test func undoingApprovalRestoresTheInbox() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID)
        let id = try ids(fixture)[0]
        let before = try fixture.snapshot()
        let approve = try operations(fixture).approve(id)
        #expect(try item(fixture, id).needsReview == false)
        _ = try await operations(fixture).undo(approve)
        #expect(ReconcileFixture.difference(try fixture.snapshot(), before) == "")
        #expect(try item(fixture, id).reviewReasons == [.lowConfidence])
    }

    @Test func reanalysingAPictureKeepsTheReviewStateRight() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let picture = try await see(fixture, [fixture.finding("Daily standup", confidence: 0.6)], picture: fixture.base.imageID)
        try fixture.save([fixture.finding("Daily standup", confidence: 0.9)], imageID: picture)
        _ = await reconciler(fixture).reconcile(imageID: picture)
        #expect(try item(fixture, try ids(fixture)[0]).needsReview == false)
    }
}
