import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct UndoTests {
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

    private func twoItems(_ fixture: ReconcileFixture) async throws -> (a: String, b: String) {
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 4")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Reunión diaria")])
        let ids = try fixture.read { try String.fetchAll($0, sql: "SELECT id FROM items ORDER BY first_seen, id") }
        return (ids[0], ids[1])
    }

    private func item(_ fixture: ReconcileFixture, _ id: String) throws -> Item { try #require(try ItemStore(database: fixture.database).item(id: id)) }
    private func opRecord(_ fixture: ReconcileFixture, _ id: OpID) throws -> OperationRecord { try #require(try OperationLog(database: fixture.database).operation(id: id)) }

    private func undone(_ result: UndoResult) -> OpID? { if case .undone(let id) = result { id } else { nil } }

    // MARK: exact restoration (SC-004)

    @Test func undoingAMergeRestoresEveryItemFieldLockAndAlias() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).edit(b, field: .notes, value: .string("agenda"))
        let before = try fixture.snapshot()
        let merge = try operations(fixture).merge(a, b)
        #expect(try fixture.snapshot() != before)
        let result = try await operations(fixture).undo(merge)
        #expect(undone(result) != nil)
        let afterUndo = try fixture.snapshot()
        #expect(ReconcileFixture.difference(afterUndo, before) == "")
        #expect(try item(fixture, b).status == .active)
    }

    @Test func undoingAMergeWithAChosenLockRestoresBothLocks() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        try operations(fixture).edit(a, field: .place, value: .string("Room 1"))
        try operations(fixture).edit(b, field: .place, value: .string("Room 2"))
        let before = try fixture.snapshot()
        let merge = try operations(fixture).merge(a, b, lockChoices: [.place: b])
        _ = try await operations(fixture).undo(merge)
        let afterUndo = try fixture.snapshot()
        #expect(ReconcileFixture.difference(afterUndo, before) == "")
        #expect(try item(fixture, a).place == "Room 1" && item(fixture, b).place == "Room 2")
    }

    @Test func undoingASplitJoinsTheSightingsAgainAndRemovesTheNewItem() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 4")])
        let original = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }
        let second = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM sightings ORDER BY captured_at DESC") ?? "" }
        let before = try fixture.snapshot()
        let (split, _) = try operations(fixture).split(original, sightings: [second])
        _ = try await operations(fixture).undo(split)
        #expect(try fixture.snapshot() == before)
        #expect(try fixture.count("keep_apart") == 0)
    }

    @Test func undoingEditUnlockDismissAndRestoreRestoresTheState() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, _) = try await twoItems(fixture)
        let ops = operations(fixture)
        var snapshots: [[String]] = [try fixture.snapshot()]
        let edit = try ops.edit(a, field: .place, value: .string("Room 9")); snapshots.append(try fixture.snapshot())
        let unlock = try ops.unlock(a, field: .place); snapshots.append(try fixture.snapshot())
        let dismiss = try ops.dismiss(a); snapshots.append(try fixture.snapshot())
        let restore = try ops.restore(a); snapshots.append(try fixture.snapshot())
        // newest first: each undo returns the table to what it was before that operation
        for (index, op) in [restore, dismiss, unlock, edit].enumerated() {
            let result = try await ops.undo(op)
            #expect(undone(result) != nil, Comment(rawValue: "undo \(index): \(result)"))
            #expect(try fixture.snapshot() == snapshots[snapshots.count - 2 - index], "snapshot after undo \(index)")
        }
    }

    @Test func undoingADifferentMarkRestoresThePossibleDuplicate() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let before = try fixture.snapshot()
        let different = try operations(fixture).markDifferent(a, b)
        #expect(try fixture.count("possible_duplicates") == 0)
        _ = try await operations(fixture).undo(different)
        #expect(try fixture.snapshot() == before)
        #expect(try fixture.count("possible_duplicates") == 1)
    }

    // MARK: automatic merges, later

    @Test func undoingAnAutomaticMergeDaysLaterSeparatesTheSightingAndKeepsLaterOnesWhereTheyAre() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Daily standup")])
        let merge = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM reconcile_ops WHERE kind = 'auto_merge'") ?? "" }
        let third = try await see(fixture, [fixture.finding("Daily standup")])
        let itemID = try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") ?? "" }

        let result = try await operations(fixture).undo(merge)
        #expect(undone(result) != nil)
        let items = try fixture.read { try Row.fetchAll($0, sql: "SELECT id FROM items") }
        #expect(items.count == 2)
        let owner = { (image: String) throws -> String? in try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE image_id = ?", arguments: [image]) } }
        #expect(try owner(second) != itemID)
        #expect(try owner(third) == itemID)
        #expect(try fixture.count("keep_apart") == 1)
        // and a reanalysis of the separated picture does not put it back
        try fixture.save([fixture.finding("Daily standup")], imageID: second)
        _ = await reconciler(fixture).reconcile(imageID: second)
        #expect(try owner(second) != itemID)
        #expect(try fixture.count("items") == 2)
    }

    @Test func undoingAMergeAfterLaterCapturesJoinedTheSurvivorLeavesTheLaterSightingsWithIt() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let merge = try operations(fixture).merge(a, b)
        let later = try await see(fixture, [fixture.finding("Daily standup")])
        let result = try await operations(fixture).undo(merge)
        #expect(undone(result) != nil)
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE image_id = ?", arguments: [later]) }
        #expect(owner == a)
        #expect(try item(fixture, b).status == .active)
    }

    // MARK: not everything can be undone

    @Test func anOperationCanBeUndoneOnlyOnce() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, _) = try await twoItems(fixture)
        let dismiss = try operations(fixture).dismiss(a)
        _ = try await operations(fixture).undo(dismiss)
        let again = try await operations(fixture).undo(dismiss)
        #expect(again == .impossible(reason: "already undone"))
        let missing = try await operations(fixture).undo("nobody")
        #expect(missing == .impossible(reason: "operation not found"))
    }

    @Test func undoIsItselfRecordedAndUndoable() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let merge = try operations(fixture).merge(a, b)
        let merged = try fixture.snapshot()
        let undoID = try #require(undone(try await operations(fixture).undo(merge)))
        let record = try opRecord(fixture, undoID)
        #expect(record.kind == .undo && record.byUser && record.detail["undone"] == .string(merge))
        #expect(try opRecord(fixture, merge).undoneBy == undoID)
        let redo = try await operations(fixture).undo(undoID)           // undoing the undo merges them again
        #expect(undone(redo) != nil)
        let afterRedo = try fixture.snapshot()
        #expect(ReconcileFixture.difference(afterRedo, merged) == "")
    }

    @Test func aLaterOperationOnTheSameItemMakesTheUndoPartial() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let merge = try operations(fixture).merge(a, b)
        try operations(fixture).dismiss(a)                                // a later change to the survivor
        let result = try await operations(fixture).undo(merge)
        guard case .partly(_, let reason) = result else { Issue.record("expected a partial undo, got \(result)"); return }
        #expect(reason.contains("later"))
        // the sighting went back, the survivor's own state was left alone
        #expect(try item(fixture, a).status == .dismissed && item(fixture, b).status == .active)
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE title = 'Reunión diaria'") }
        #expect(owner == b)
    }

    @Test func anOperationWhoseSightingsWereRemovedByCleanupCannotBeUndone() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let (a, b) = try await twoItems(fixture)
        let merge = try operations(fixture).merge(a, b)
        let image = try fixture.read { try String.fetchOne($0, sql: "SELECT image_id FROM sightings WHERE title = 'Reunión diaria'") ?? "" }
        let event = try fixture.read { try String.fetchOne($0, sql: "SELECT event_id FROM capture_images WHERE id = ?", arguments: [image]) ?? "" }
        try fixture.base.captures.deleteEvents(ids: [event])
        try ItemStore(database: fixture.database).sweep(at: clock)
        let before = try fixture.snapshot()
        let result = try await operations(fixture).undo(merge)
        guard case .impossible = result else { Issue.record("expected impossible, got \(result)"); return }
        #expect(try fixture.snapshot() == before)
        #expect(try opRecord(fixture, merge).undoneBy == nil)
    }

    // MARK: context change

    @Test func changingThePicturesContextMatchesItsSightingsAgainAndCanBeUndone() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("c1", "Customer A"); try fixture.addContext("c2", "Customer B")
        let image = try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID, context: "c1")
        let other = try await see(fixture, [fixture.finding("Daily standup")], context: "c2")
        #expect(try fixture.count("items") == 2)
        let before = try fixture.snapshot()

        let change = try await operations(fixture).changeContext(imageID: image, to: "c2")
        let items = try fixture.read { try Row.fetchAll($0, sql: "SELECT id, context_id, title FROM items") }
        #expect(items.count == 1, Comment(rawValue: "items: \(items)"))
        #expect(items.first?["context_id"] as String? == "c2")            // joined the c2 item; the empty c1 item went
        #expect(try fixture.count("sightings") == 2)
        let choice = try fixture.read { try Row.fetchOne($0, sql: "SELECT context_id, source FROM image_context WHERE image_id = ?", arguments: [image]) }
        #expect(choice?["context_id"] as String? == "c2" && choice?["source"] as String? == "user")
        let record = try opRecord(fixture, change)
        #expect(record.kind == .context && record.byUser && record.detail["from"] == .string("c1") && record.detail["to"] == .string("c2"))

        let result = try await operations(fixture).undo(change)
        #expect(undone(result) != nil)
        let restored = try fixture.read { try Row.fetchOne($0, sql: "SELECT context_id, source FROM image_context WHERE image_id = ?", arguments: [image]) }
        #expect(restored?["context_id"] as String? == "c1" && restored?["source"] as String? == "auto")
        let after = try fixture.read { try Row.fetchAll($0, sql: "SELECT context_id FROM items ORDER BY context_id") }
        #expect(after.map { $0["context_id"] as String? } == ["c1", "c2"])
        _ = (before, other)
    }

    @Test func changingTheContextNeedsAReconciler() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let ops = ItemOperations(database: fixture.database, now: { clock })
        await #expect(throws: ItemOperationError.noReconciler) { _ = try await ops.changeContext(imageID: fixture.base.imageID, to: nil) }
    }
}
