import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// A run of sync against a fake system store (spec 009): what is written, where, and what is left alone.
@Suite struct SyncEngineTests {
    private let clock = Date(timeIntervalSince1970: 1_791_961_200 + 86_400)

    private struct Setup {
        let fixture: ReconcileFixture
        let events: FakeEventStore
        let store: SyncStore
        let engine: SyncEngine
        let operations: ItemOperations
    }

    /// Items "Standup" and "Budget review" (appointments) and "Pay invoice" (a task), all approved; calendar and list set to the ones named Memorri.
    private func setup(items: [String] = ["Standup", "Budget review", "Pay invoice"], target: Bool = true) async throws -> Setup {
        let fixture = try ReconcileFixture()
        let reconciler = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { clock })
        var pictureID = fixture.base.imageID
        for (index, title) in items.enumerated() {
            if index > 0 { pictureID = try fixture.addPicture(at: Date(timeIntervalSince1970: 1_791_961_200 + Double(index) * 3600)) }
            let task = title.hasPrefix("Pay")
            try fixture.save([task ? fixture.finding(title, start: nil, kind: .task, due: ReconcileFixture.minutes(60 * (index + 1)))
                                   : fixture.finding(title, start: ReconcileFixture.minutes(30 * (index + 1)), end: ReconcileFixture.minutes(30 * (index + 1) + 30))],
                         imageID: pictureID)
            _ = await reconciler.reconcile(imageID: pictureID)
        }
        let operations = ItemOperations(database: fixture.database, now: { clock })
        for id in try fixture.read({ try String.fetchAll($0, sql: "SELECT id FROM items") }) { _ = try? operations.approve(id) }
        let events = FakeEventStore()
        let store = SyncStore(database: fixture.database, settings: FakeSettingsStore())
        if target { store.setCalendarID("cal-memorri"); store.setListID("list-memorri") }
        store.setEnabled(true)
        return Setup(fixture: fixture, events: events, store: store, engine: SyncEngine(database: fixture.database, store: store, events: events, operations: operations, now: { clock }),
                     operations: operations)
    }

    private func itemID(_ s: Setup, _ title: String) throws -> String {
        try s.fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = ?", arguments: [title]) } ?? ""
    }

    private func state(_ s: Setup, _ id: String) -> SyncLinkState? { (try? s.store.link(itemID: id))?.map(\.state) ?? nil }
    private func linked(_ s: Setup, _ id: String) -> Bool { ((try? s.store.link(itemID: id)) ?? nil) != nil }
    private func linkStates(_ s: Setup) -> [SyncLinkState] { ((try? s.store.links()) ?? [:]).values.map(\.state) }

    @Test func theFirstRunWritesOnlyInTheChosenCalendarAndListAndASecondRunWritesNothing() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        let outcome = await s.engine.run()
        #expect(outcome.problem == nil && outcome.run.created == 3 && outcome.run.failed == 0)
        #expect(s.events.writes.count == 3 && Set(s.events.writes.map(\.container)) == ["cal-memorri", "list-memorri"])
        #expect(s.events.entries.values.filter { $0.entry.kind == .event }.count == 2 && s.events.entries.values.filter { $0.entry.kind == .reminder }.count == 1)
        #expect(linkStates(s).count == 3 && linkStates(s).allSatisfy { $0 == .synced })

        s.events.clearWrites()
        let again = await s.engine.run()
        #expect(s.events.writes.isEmpty && again.run.created == 0 && again.run.updated == 0 && again.run.failed == 0)
    }

    @Test func aPreviewMakesThePlanAndWritesNothing() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        let outcome = await s.engine.preview()
        #expect(outcome.run.preview && outcome.run.created == 3 && outcome.plan.created == 3)
        #expect(s.events.writes.isEmpty && s.events.entries.isEmpty)
        #expect(try s.store.links().isEmpty)
    }

    @Test func entriesOfTheUsersOwnInOtherCalendarsAndListsAreNeverTouched() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        let work = s.events.seedForeign(in: "cal-work", title: "Standup")                // the same title as one of ours
        let personal = s.events.seedForeign(in: "cal-personal", title: "Dentist")
        let home = s.events.seedForeign(in: "list-home", title: "Milk", kind: .reminder)
        let before = [work, personal, home].map { s.events.entries[$0] }
        _ = await s.engine.run()
        let id = try itemID(s, "Standup")
        _ = try s.operations.dismiss(id)
        _ = await s.engine.run()
        #expect([work, personal, home].map { s.events.entries[$0] } == before)
        #expect(s.events.writes.allSatisfy { ["cal-memorri", "list-memorri"].contains($0.container) })
    }

    @Test func withNoCalendarChosenNoEventIsWrittenAndWithNeitherNothingRuns() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        s.store.setCalendarID(nil)
        let outcome = await s.engine.run()
        #expect(outcome.run.created == 1 && outcome.run.skipped == 2)                    // only the reminder
        #expect(s.events.entries.values.allSatisfy { $0.entry.kind == .reminder })
        s.store.setListID(nil)
        let none = await s.engine.run()
        #expect(none.problem == .notSetUp && s.events.writes.count == 1)
    }

    @Test func noAccessAndAMissingTargetAreReportedAndNothingIsWritten() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        s.events.eventAccess = .denied
        let denied = await s.engine.run()
        #expect(denied.problem == .noAccess(.event) && s.events.writes.isEmpty)
        s.events.eventAccess = .allowed
        s.events.calendars.removeAll { $0.id == "cal-memorri" }
        let gone = await s.engine.run()
        #expect(gone.problem == .targetGone(.event) && s.events.writes.isEmpty)
    }

    @Test func itemsInTheInboxAreNotWrittenUntilApproved() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        let id = try itemID(s, "Budget review")
        try s.fixture.write { try $0.execute(sql: "UPDATE items SET needs_review = 1, approved_at = NULL WHERE id = ?", arguments: [id]) }
        let outcome = await s.engine.run()
        #expect(outcome.run.created == 2 && !linked(s, id))
        _ = try s.operations.approve(id)
        let later = await s.engine.run()
        #expect(later.run.created == 1 && linked(s, id))
    }

    @Test func aChangeInMemorriUpdatesTheSameEntryAndDoesNotDuplicateIt() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        _ = await s.engine.run()
        let id = try itemID(s, "Standup")
        let ekID = try #require(try s.store.link(itemID: id)).ekID
        _ = try s.operations.edit(id, field: .place, value: .string("Room 9"))
        s.events.clearWrites()
        let outcome = await s.engine.run()
        #expect(outcome.run.updated == 1 && s.events.writes == [.init(op: "update", id: ekID, container: "cal-memorri")])
        #expect(s.events.entries[ekID]?.entry.location == "Room 9" && s.events.entries.count == 3)
    }

    @Test func aDismissedItemIsRemovedAndRestoringItWritesItAgain() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        _ = await s.engine.run()
        let id = try itemID(s, "Budget review")
        _ = try s.operations.dismiss(id)
        let removed = await s.engine.run()
        #expect(removed.run.removed == 1 && s.events.entries.count == 2 && state(s, id) == .removed)
        _ = try s.operations.restore(id)
        let restored = await s.engine.run()
        #expect(restored.run.created == 1 && s.events.entries.count == 3 && state(s, id) == .synced)
    }

    @Test func oneFailingItemDoesNotStopTheOthers() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        s.events.failTitles = ["Budget review"]
        let outcome = await s.engine.run()
        #expect(outcome.run.created == 2 && outcome.run.failed == 1 && outcome.run.detail.count == 1)
        #expect(!outcome.run.detail.joined().contains("Budget"))                         // never an item's content
        s.events.failTitles = []
        let retry = await s.engine.run()
        #expect(retry.run.created == 1 && retry.run.failed == 0)
    }

    @Test func anEditMadeInCalendarIsAdoptedLockedAndWrittenBackWithoutLoss() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        _ = await s.engine.run()
        let id = try itemID(s, "Standup")
        let link = try #require(try s.store.link(itemID: id))
        let newStart = ReconcileFixture.minutes(90)
        s.events.edit(link.ekID) { $0.entry.title = "Daily standup"; $0.entry.start = newStart; $0.entry.end = newStart.addingTimeInterval(1800) }
        let outcome = await s.engine.run()
        #expect(outcome.run.adopted == 1 && outcome.run.failed == 0)
        let item = try #require(try ItemStore(database: s.fixture.database).item(id: id))
        #expect(item.title == "Daily standup" && item.start == newStart)
        let locked = try s.fixture.read { try String.fetchAll($0, sql: "SELECT field FROM field_locks WHERE item_id = ? ORDER BY field", arguments: [id]) }
        #expect(locked.contains("title") && locked.contains("start"))
        #expect(s.events.entries[link.ekID]?.entry.title == "Daily standup" && s.events.entries.count == 3)
        s.events.clearWrites()
        _ = await s.engine.run()
        #expect(s.events.writes.isEmpty)
    }

    @Test func anEntryTheUserDeletedIsNotRecreatedUntilSyncAgainIsChosen() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        _ = await s.engine.run()
        let id = try itemID(s, "Standup")
        s.events.remove(try #require(try s.store.link(itemID: id)).ekID)
        s.events.clearWrites()
        let outcome = await s.engine.run()
        #expect(s.events.writes.isEmpty && outcome.run.created == 0)
        #expect(state(s, id) == .removedByUser)
        try s.store.syncAgain(itemID: id)
        let again = await s.engine.run()
        #expect(again.run.created == 1 && s.events.entries.count == 3)
    }

    @Test func aReminderCompletedInRemindersStaysCompletedAndIsNotWrittenOver() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        _ = await s.engine.run()
        let id = try itemID(s, "Pay invoice")
        let link = try #require(try s.store.link(itemID: id))
        s.events.edit(link.ekID) { $0.completed = true }
        s.events.clearWrites()
        _ = await s.engine.run()
        #expect(state(s, id) == .completed && s.events.writes.isEmpty)
        let item = try #require(try ItemStore(database: s.fixture.database).item(id: id))
        #expect(item.status == .active)                                                  // never closes an item in Memorri
    }

    @Test func choosingAnotherCalendarMovesTheEntriesOnlyAfterConfirmation() async throws {
        let s = try await setup(); defer { s.fixture.cleanUp() }
        s.events.calendars.append(SyncContainer(id: "cal-new", name: "Memorri 2", account: "iCloud", kind: .event))
        _ = await s.engine.run()
        s.store.setCalendarID("cal-new")
        s.events.clearWrites()
        let held = await s.engine.run()
        #expect(s.events.writes.isEmpty && held.run.detail.count == 2)                   // two events wait for confirmation
        let moved = await s.engine.run(allowMove: true)
        #expect(moved.run.failed == 0 && s.events.entries.values.filter { $0.entry.kind == .event }.allSatisfy { $0.containerID == "cal-new" })
        #expect(s.events.entries.count == 3)
    }

    @Test func aThousandItemsAreWrittenQuicklyAndASecondRunIsCheap() async throws {
        let s = try await setup(items: ["Standup"]); defer { s.fixture.cleanUp() }
        try s.fixture.write { db in
            for n in 0..<999 {
                try db.execute(sql: """
                    INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at, start_at, end_at, needs_review)
                    VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'), ?, ?, 0)
                    """, arguments: ["bulk\(n)", "Meeting \(n)", ReconcileFixture.minutes(60 + n), ReconcileFixture.minutes(90 + n)])
            }
        }
        let started = Date()
        let first = await s.engine.run()
        #expect(first.run.created == 1_000 && first.run.failed == 0)
        s.events.clearWrites()
        let second = await s.engine.run()
        #expect(s.events.writes.isEmpty && second.run.created == 0)
        #expect(Date().timeIntervalSince(started) < 60)
    }
}
