import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ItemMergeSplitTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations { ItemOperations(database: fixture.database, now: { clock }) }

    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil, hour: Int? = nil) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(hour ?? fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id)
        let summary = await reconciler(fixture).reconcile(imageID: id)
        #expect(summary.error == nil)
        return id
    }

    /// Two items for one event: the translated title could not be judged, so it stayed apart as a possible duplicate.
    private func twoItems(_ fixture: ReconcileFixture) async throws -> (a: String, b: String) {
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Reunión diaria")])
        let ids = try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM items ORDER BY first_seen, id") }
        #expect(ids.count == 2)
        return (ids[0], ids[1])
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }
    private func record(_ fixture: ReconcileFixture, _ id: OpID) throws -> OperationRecord { try #require(try OperationLog(database: fixture.database).operation(id: id)) }
    private func sightings(_ fixture: ReconcileFixture, _ id: String) throws -> Int {
        try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sightings WHERE item_id = ?", arguments: [id]) ?? 0 }
    }

    // MARK: merge

    @Test func mergingMovesEverythingToTheSurvivorAndRecordsTheOtherAsMerged() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        #expect(try fixture.count("possible_duplicates") == 1)
        let opID = try operations(fixture).merge(a, b)
        let survivor = try item(fixture, a), gone = try item(fixture, b)
        #expect(gone.status == .merged && gone.mergedInto == a && gone.userTouched)
        #expect(survivor.userTouched && survivor.status == .active)
        #expect(try sightings(fixture, a) == 2 && sightings(fixture, b) == 0)
        let aliases = try fixture.read { try String.fetchAll($0, sql: "SELECT title FROM item_aliases WHERE item_id = ?", arguments: [a]) }
        #expect(aliases.contains("Reunión diaria") && aliases.contains("Daily standup"))
        #expect(try fixture.count("possible_duplicates") == 0)
        let observed = try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE item_id = ?", arguments: [b]) }
        #expect(observed == 0)
        let op = try record(fixture, opID)
        #expect(op.kind == .merge && op.byUser && op.itemIDs == [a, b] && op.moved.count == 1 && op.moved[0].from == b && op.moved[0].to == a)
        #expect(op.before[a]?.status == "active" && op.before[b]?.status == "active")
    }

    @Test func aLockMovesToTheSurvivorWhenItHasNoneOfItsOwn() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).edit(b, field: .place, value: .string("Room 9"))
        try operations(fixture).merge(a, b)
        let survivor = try item(fixture, a)
        #expect(survivor.place == "Room 9")
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM field_locks WHERE field = 'place'") }
        #expect(owner == a)
    }

    @Test func conflictingLocksNeedAChoiceAndChangeNothingUntilItIsMade() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).edit(a, field: .place, value: .string("Room 1"))
        try operations(fixture).edit(b, field: .place, value: .string("Room 2"))
        let before = try fixture.snapshot()
        let opsBefore = try fixture.count("reconcile_ops")
        #expect(throws: ItemOperationError.needsLockChoice([.place])) { try operations(fixture).merge(a, b) }
        #expect(try fixture.snapshot() == before && fixture.count("reconcile_ops") == opsBefore)
        #expect(throws: ItemOperationError.invalidValue) { try operations(fixture).merge(a, b, lockChoices: [.place: "someone-else"]) }

        let opID = try operations(fixture).merge(a, b, lockChoices: [.place: b])
        #expect(try item(fixture, a).place == "Room 2")
        #expect(try record(fixture, opID).detail["lockChoices"] == .object(["place": .string(b)]))
        #expect(try fixture.count("field_locks") == 1)
    }

    @Test func theSurvivorsLockWinsWhenThatWasTheChoiceAndEqualLocksNeedNoChoice() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).edit(a, field: .place, value: .string("Room 1"))
        try operations(fixture).edit(b, field: .place, value: .string("Room 2"))
        try operations(fixture).merge(a, b, lockChoices: [.place: a])
        #expect(try item(fixture, a).place == "Room 1")

        let other = try ReconcileFixture(); defer { other.cleanUp() }
        let (c, d) = try await twoItems(other)
        try operations(other).edit(c, field: .place, value: .string("Same room"))
        try operations(other).edit(d, field: .place, value: .string("Same room"))
        try operations(other).merge(c, d)                          // no choice needed
        #expect(try item(other, c).place == "Same room")
    }

    @Test func mergingAnItemWithItselfAMergedItemOrAMissingOneIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).merge(a, b)
        #expect(throws: ItemOperationError.sameItem) { try operations(fixture).merge(a, a) }
        #expect(throws: ItemOperationError.merged) { try operations(fixture).merge(a, b) }
        #expect(throws: ItemOperationError.merged) { try operations(fixture).merge(b, a) }
        #expect(throws: ItemOperationError.notFound) { try operations(fixture).merge(a, "nobody") }
    }

    // MARK: split

    @Test func splittingMakesANewItemOfTheChosenSightingsAndKeepsTheTwoApart() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup")])
        try await see(fixture, [fixture.finding("Daily stand…", place: "Room 4")])
        let original = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        try operations(fixture).edit(original, field: .notes, value: .string("agenda"))
        let truncated = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM sightings WHERE title = 'Daily stand…'") ?? "" }

        let (opID, created) = try operations(fixture).split(original, sightings: [truncated])
        let newItem = try item(fixture, created), kept = try item(fixture, original)
        #expect(try sightings(fixture, created) == 1 && sightings(fixture, original) == 2)
        #expect(newItem.title == "Daily stand…" && newItem.place == "Room 4" && newItem.userTouched && newItem.status == .active)
        #expect(kept.place == nil && kept.notes == "agenda")             // the lock stays with the original
        let aliases = try fixture.read { try String.fetchAll($0, sql: "SELECT title FROM item_aliases WHERE item_id = ?", arguments: [original]) }
        #expect(!aliases.contains("Daily stand…"))
        let pair = [original, created].sorted()
        let apart = try fixture.read { try Row.fetchAll($0, sql: "SELECT item_a, item_b, op_id FROM keep_apart") }
        #expect(apart.count == 1 && apart[0]["item_a"] as String == pair[0] && apart[0]["item_b"] as String == pair[1] && apart[0]["op_id"] as String == opID)
        let op = try record(fixture, opID)
        #expect(op.kind == .split && op.byUser && Set(op.itemIDs) == [original, created] && op.moved == [MovedSighting(sighting: truncated, from: original, to: created)])
        #expect(op.detail["new"] == .string(created))
    }

    @Test func aSplitThatTakesNothingEverythingOrSomeoneElsesSightingsIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup")])
        try await see(fixture, [fixture.finding("Other thing", start: ReconcileFixture.minutes(300))])
        let items = try fixture.read { try Row.fetchAll($0, sql: "SELECT id, title FROM items") }
        let standup = try #require(items.first { $0["title"] as String == "Daily standup" })["id"] as String
        let other = try #require(items.first { $0["title"] as String == "Other thing" })["id"] as String
        let mine = try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM sightings WHERE item_id = ?", arguments: [standup]) }
        let foreign = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM sightings WHERE item_id = ?", arguments: [other]) ?? "" }
        let before = try fixture.snapshot()
        let opsBefore = try fixture.count("reconcile_ops")
        for chosen in [[], mine, [foreign], [mine[0], foreign]] {
            #expect(throws: ItemOperationError.invalidSightings) { try operations(fixture).split(standup, sightings: chosen) }
        }
        #expect(try fixture.snapshot() == before && fixture.count("reconcile_ops") == opsBefore)
    }

    @Test func afterASplitReanalysingThePictureKeepsTheFindingWhereItWasPutAndNothingJoinsThemAgain() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Daily standup")])
        let original = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        let sighting = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM sightings WHERE image_id = ?", arguments: [second]) ?? "" }
        let (_, created) = try operations(fixture).split(original, sightings: [sighting])

        try fixture.save([fixture.finding("Daily standup")], imageID: second)             // reanalysis
        _ = await reconciler(fixture).reconcile(imageID: second)
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE image_id = ?", arguments: [second]) }
        #expect(owner == created)
        #expect(try fixture.count("items") == 2)

        try await see(fixture, [fixture.finding("Daily standup")])                         // a new capture joins one of them, never both
        #expect(try fixture.count("items") == 2 && fixture.count("keep_apart") == 1)
    }

    // MARK: different

    @Test func markingAPairDifferentClearsThePossibleDuplicateAndKeepsThemApart() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let opID = try operations(fixture).markDifferent(b, a)
        #expect(try fixture.count("possible_duplicates") == 0 && fixture.count("keep_apart") == 1)
        let op = try record(fixture, opID)
        #expect(op.kind == .different && op.byUser && Set(op.itemIDs) == [a, b])
        #expect(op.detail["scores"]?.asString?.contains("text") == true)
        #expect(throws: ItemOperationError.sameItem) { try operations(fixture).markDifferent(a, a) }
        #expect(throws: ItemOperationError.notFound) { try operations(fixture).markDifferent(a, "nobody") }
    }
}
