import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// A value the user sets stays through later sightings of the same event; Unlock gives the decision back to the sightings (spec 006, US3).
@Suite struct EditLockTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations { ItemOperations(database: fixture.database, now: { clock }) }

    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id)
        let summary = await reconciler(fixture).reconcile(imageID: id)
        #expect(summary.error == nil)
        return id
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }

    @Test func editedValuesSurviveALaterCaptureShowingTheOldOnesAndStayLocked() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), people: ["Anna"], place: "Room 4")],
                      picture: fixture.base.imageID)
        let id = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        let ops = operations(fixture)
        let newStart = ReconcileFixture.minutes(15)
        try ops.edit(id, field: .start, value: .date(newStart))
        try ops.edit(id, field: .place, value: .string("Room 9"))
        try ops.edit(id, field: .people, value: .array([.string("Zoe")]))
        try ops.edit(id, field: .notes, value: .string("bring the agenda"))

        // The same event is captured again, showing the old values.
        try await see(fixture, [fixture.finding("Daily standup", start: newStart, end: ReconcileFixture.minutes(60), people: ["Anna"], place: "Room 4")])
        let after = try item(fixture, id)
        #expect(after.start == newStart && after.place == "Room 9" && after.people == ["Zoe"] && after.notes == "bring the agenda")
        let locked = try fixture.read { try String.fetchAll($0, sql: "SELECT field FROM field_locks WHERE item_id = ? ORDER BY field", arguments: [id]) }
        #expect(locked == ["notes", "people", "place", "start"])

        // The other values stay visible as observations of the field.
        let detail = try ItemStore(database: fixture.database).detail(itemID: id)
        let place = try #require(detail.fields.first { $0.field == .place })
        #expect(place.locked && place.entries.contains { $0.value == .string("Room 9") } && place.entries.contains { $0.value == .string("Room 4") })
        #expect(place.entries.contains { $0.source == .user } && place.entries.contains { $0.source == .read })
        let people = try #require(detail.fields.first { $0.field == .people })
        #expect(people.entries.contains { $0.value == .array([.string("Anna")]) })
    }

    @Test func unlockReturnsTheValueTheSightingsDecideAndTheDetailSaysWhichOne() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 4")], picture: fixture.base.imageID)
        let id = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        let ops = operations(fixture)
        try ops.edit(id, field: .place, value: .string("Room 9"))
        try ops.unlock(id, field: .place)
        #expect(try item(fixture, id).place == "Room 4")
        let detail = try ItemStore(database: fixture.database).detail(itemID: id)
        let place = try #require(detail.fields.first { $0.field == .place })
        #expect(!place.locked && place.current == .string("Room 4"))
        let text = ItemListModel.fieldText(place, timezone: "UTC")
        #expect(text.value == "Room 4" && text.source == "read")
        // the user's value is kept as history
        #expect(place.entries.contains { $0.source == .user && $0.value == .string("Room 9") })
    }

    @Test func aLockedClearedFieldShowsNoneAndYou() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 4")], picture: fixture.base.imageID)
        let id = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        try operations(fixture).edit(id, field: .place, value: .null)
        let place = try #require(try ItemStore(database: fixture.database).detail(itemID: id).fields.first { $0.field == .place })
        let text = ItemListModel.fieldText(place, timezone: "UTC")
        #expect(text.value == "none" && text.source == "you" && place.locked)
    }
}
