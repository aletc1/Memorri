import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ItemOperationsTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations { ItemOperations(database: fixture.database, now: { clock }) }

    /// One item, seen once, with a place and a guessed end.
    private func oneItem(_ fixture: ReconcileFixture) async throws -> String {
        try fixture.save([fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), inferredEnd: true, place: "Room 4")])
        _ = await Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
            .reconcile(imageID: fixture.base.imageID)
        return try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }

    private func op(_ fixture: ReconcileFixture, _ id: OpID) throws -> OperationRecord { try #require(try OperationLog(database: fixture.database).operation(id: id)) }

    // MARK: edit

    @Test func editingTheTitleWritesALockedUserObservationAndKeepsTheOldTitleAsAnAlias() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let opID = try operations(fixture).edit(id, field: .title, value: .string("My standup"))
        let after = try item(fixture, id)
        #expect(after.title == "My standup" && after.userTouched)
        let user = try fixture.read { try Row.fetchAll($0, sql: "SELECT * FROM observations WHERE source = 'user'") }
        #expect(user.count == 1 && (user[0]["confidence"] as Double) == 1 && (user[0]["sighting_id"] as String?) == nil)
        #expect(try fixture.count("field_locks") == 1)
        let aliases = try fixture.read { try String.fetchAll($0, sql: "SELECT title FROM item_aliases WHERE item_id = ?", arguments: [id]) }
        #expect(aliases.contains("Daily standup") && aliases.contains("My standup"))
        let record = try op(fixture, opID)
        #expect(record.kind == .edit && record.byUser && record.itemIDs == [id])
        #expect(record.detail["field"] == .string("title") && record.detail["observation"] == .string(user[0]["id"] as String))
    }

    @Test func theBeforeStateOfAnEditHoldsTheLocksThatWereThere() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let first = try operations(fixture).edit(id, field: .place, value: .string("Room 9"))
        let second = try operations(fixture).edit(id, field: .place, value: .string("Room 10"))
        #expect(try op(fixture, first).before[id] == ItemState(status: "active", mergedInto: nil, userTouched: false, locks: [:], observations: []))
        let before = try #require(try op(fixture, second).before[id])
        #expect(before.userTouched && before.locks.keys.sorted() == ["place"] && before.observations.count == 1)
        #expect(try item(fixture, id).place == "Room 10")
    }

    @Test func editingDatesPeopleAndFlagsUsesTheMatchingValueTypes() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let ops = operations(fixture)
        let start = ReconcileFixture.minutes(45)
        try ops.edit(id, field: .start, value: .date(start))
        try ops.edit(id, field: .people, value: .array([.string("Anna"), .string("Ben")]))
        try ops.edit(id, field: .allDay, value: .bool(false))
        let after = try item(fixture, id)
        #expect(after.start == start && after.people == ["Anna", "Ben"] && !after.allDay)
        #expect(after.dayKey == "2026-10-14")
    }

    @Test func invalidValuesAreRefusedAndNothingChanges() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let ops = operations(fixture)
        let bad: [(ItemField, JSONValue)] = [(.title, .int(3)), (.title, .string("   ")), (.start, .string("tomorrow")), (.start, .null),
                                             (.allDay, .string("yes")), (.people, .string("Anna")), (.place, .bool(true))]
        for (field, value) in bad {
            #expect(throws: ItemOperationError.invalidValue) { try ops.edit(id, field: field, value: value) }
        }
        #expect(try fixture.count("field_locks") == 0 && fixture.count("reconcile_ops") == 0)
        #expect(try item(fixture, id).userTouched == false)
    }

    @Test func actingOnAMissingOrMergedItemIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "gone"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "UPDATE items SET status = 'merged', merged_into = ? WHERE id = 'gone'", arguments: [id])
        }
        let ops = operations(fixture)
        #expect(throws: ItemOperationError.notFound) { try ops.edit("nobody", field: .title, value: .string("x")) }
        #expect(throws: ItemOperationError.merged) { try ops.edit("gone", field: .title, value: .string("x")) }
        #expect(throws: ItemOperationError.merged) { try ops.dismiss("gone") }
        #expect(throws: ItemOperationError.notFound) { try ops.unlock("nobody", field: .title) }
    }

    // MARK: unlock

    @Test func unlockingReturnsTheFieldToTheObservationsAndKeepsTheUsersValueAsHistory() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let ops = operations(fixture)
        try ops.edit(id, field: .place, value: .string("Room 9"))
        #expect(try item(fixture, id).place == "Room 9")
        let opID = try ops.unlock(id, field: .place)
        let after = try item(fixture, id)
        #expect(after.place == "Room 4" && after.userTouched)
        #expect(try fixture.count("field_locks") == 0)
        #expect(try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE source = 'user'") } == 1)
        let record = try op(fixture, opID)
        #expect(record.kind == .unlock && record.byUser && record.before[id]?.locks.keys.sorted() == ["place"])
    }

    @Test func unlockingAFieldThatIsNotLockedIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        #expect(throws: ItemOperationError.notLocked) { try operations(fixture).unlock(id, field: .place) }
        #expect(try fixture.count("reconcile_ops") == 0)
    }

    // MARK: dismiss and restore

    @Test func dismissingAndRestoringChangeTheStatusAndAreLogged() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let ops = operations(fixture)
        let dismissed = try ops.dismiss(id)
        #expect(try item(fixture, id).status == .dismissed && item(fixture, id).userTouched)
        #expect(try op(fixture, dismissed).kind == .dismiss && op(fixture, dismissed).before[id]?.status == "active")
        let restored = try ops.restore(id)
        #expect(try item(fixture, id).status == .active)
        #expect(try op(fixture, restored).kind == .restore && op(fixture, restored).before[id]?.status == "dismissed")
    }

    @Test func dismissingTwiceOrRestoringAnActiveItemIsRefused() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await oneItem(fixture)
        let ops = operations(fixture)
        #expect(throws: ItemOperationError.wrongStatus) { try ops.restore(id) }
        try ops.dismiss(id)
        #expect(throws: ItemOperationError.wrongStatus) { try ops.dismiss(id) }
        #expect(try fixture.count("reconcile_ops") == 1)
    }
}
