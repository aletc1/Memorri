import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Search always reflects the library as it is now (spec 007, FR-011, SC-003): the index is kept by the same writes that change the data.
@Suite struct SearchFreshnessTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func operations(_ fixture: ReconcileFixture) -> ItemOperations { ItemOperations(database: fixture.database, now: { clock }) }

    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id)
        _ = await reconciler(fixture).reconcile(imageID: id)
        return id
    }

    private func found(_ fixture: ReconcileFixture, _ text: String, dismissed: Bool = false) async throws -> [ItemHit] {
        try await SearchService(database: fixture.database).search(SearchQuery(text: text, includeDismissed: dismissed)).items
    }

    private func itemID(_ fixture: ReconcileFixture, titled title: String) throws -> String {
        try #require(try fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = ?", arguments: [title]) })
    }

    /// The index holds exactly one row for each item that is not merged, and nothing else.
    private func expectInStep(_ fixture: ReconcileFixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rows = try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_items") ?? -1 }
        let items = try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items WHERE status != 'merged'") ?? -2 }
        let distinct = try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT item_id) FROM search_items") ?? -3 }
        #expect(rows == items && distinct == items, "index rows \(rows), distinct \(distinct), items \(items)", sourceLocation: sourceLocation)
    }

    @Test func aNewItemAndALaterSightingUnderAnotherTitleAreFound() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup")], picture: f.base.imageID)
        #expect(try await found(f, "standup").count == 1)
        try await see(f, [f.finding("Daily standup (moved)")])
        let hits = try await found(f, "moved")
        #expect(hits.count == 1)
        #expect(try await found(f, "daily").count == 1)
        try expectInStep(f)
    }

    @Test func anEditShowsTheNewValuesAndTheOldTitleStillFindsTheItemThroughItsAlias() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup")], picture: f.base.imageID)
        let id = try itemID(f, titled: "Daily standup")
        _ = try operations(f).edit(id, field: .title, value: .string("Team sync"))
        #expect(try await found(f, "sync").first?.id == id)
        let old = try await found(f, "standup")
        #expect(old.first?.id == id && old.first?.matchedIn == .alias)
        _ = try operations(f).edit(id, field: .notes, value: .string("bring the roadmap"))
        _ = try operations(f).edit(id, field: .place, value: .string("Sala Cervantes"))
        _ = try operations(f).edit(id, field: .people, value: .array([.string("Ana Pérez")]))
        for (word, field) in [("roadmap", SearchField.notes), ("cervantes", .place), ("perez", .people)] {
            let hit = try await found(f, word).first
            #expect(hit?.id == id && hit?.matchedIn == field, "\(word)")
        }
        _ = try operations(f).edit(id, field: .notes, value: .null)
        #expect(try await found(f, "roadmap").isEmpty)
        _ = try operations(f).unlock(id, field: .title)
        _ = try operations(f).approve(id)
        #expect(try await found(f, "sync").count == 1)
        try expectInStep(f)
    }

    @Test func dismissedItemsAreHiddenUnlessAskedForAndRestoredOnesComeBack() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup")], picture: f.base.imageID)
        let id = try itemID(f, titled: "Daily standup")
        _ = try operations(f).dismiss(id)
        #expect(try await found(f, "standup").isEmpty)
        let shown = try await found(f, "standup", dismissed: true)
        #expect(shown.count == 1 && shown.first?.status == .dismissed)
        _ = try operations(f).restore(id)
        #expect(try await found(f, "standup").first?.status == .active)
        try expectInStep(f)
    }

    @Test func mergingLeavesOneItemForEitherTitleAndUndoingGivesTwo() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup")], picture: f.base.imageID)
        try await see(f, [f.finding("Reunión diaria")])
        let a = try itemID(f, titled: "Daily standup"), b = try itemID(f, titled: "Reunión diaria")
        let beforeFirst = try await found(f, "standup"), beforeSecond = try await found(f, "reunion")
        #expect(beforeFirst.count == 1 && beforeSecond.count == 1)
        let merge = try operations(f).merge(a, b)
        let byFirst = try await found(f, "standup"), bySecond = try await found(f, "reunion")
        #expect(byFirst.map(\.id) == [a] && bySecond.map(\.id) == [a])
        try expectInStep(f)
        _ = try await operations(f).undo(merge)
        let first = try await found(f, "standup"), second = try await found(f, "reunion")
        #expect(first.map(\.id) == [a] && second.map(\.id) == [b])
        try expectInStep(f)
    }

    @Test func splittingGivesTheNewItemItsOwnRow() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup")], picture: f.base.imageID)
        try await see(f, [f.finding("Daily standup (moved)")])
        let id = try #require(try f.read { try String.fetchOne($0, sql: "SELECT id FROM items") })      // the second sighting joined the first item
        let sighting = try #require(try f.read { try String.fetchOne($0, sql: "SELECT id FROM sightings WHERE item_id = ? AND title LIKE '%moved%'", arguments: [id]) })
        let split = try operations(f).split(id, sightings: [sighting])
        let moved = try await found(f, "moved")
        #expect(moved.map(\.id).contains(split.newItem))
        try expectInStep(f)
    }

    @Test func theSweepAfterRetentionRemovesAnUntouchedItemAndKeepsAnEditedOne() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try await see(f, [f.finding("Daily standup"), f.finding("Dentist", start: ReconcileFixture.minutes(300))], picture: f.base.imageID)
        let edited = try itemID(f, titled: "Dentist")
        _ = try operations(f).edit(edited, field: .notes, value: .string("bring the card"))
        try f.base.captures.deleteEvents(ids: try f.read { try String.fetchAll($0, sql: "SELECT id FROM capture_events") })
        _ = try ItemStore(database: f.database).sweep(at: clock)
        #expect(try await found(f, "standup").isEmpty)
        #expect(try await found(f, "dentist").count == 1)
        try expectInStep(f)
    }

    // MARK: captures and retention

    private func service(_ f: EvidenceFixture) -> SearchService { SearchService(database: f.database) }

    private func cleanup(_ f: EvidenceFixture, now: Date) -> CleanupService {
        CleanupService(paths: f.paths, store: f.fixture.base.captures, files: CaptureFileStore(paths: f.paths), time: FakeTimeSource(now.timeIntervalSinceReferenceDate))
    }

    private func table(_ f: EvidenceFixture, _ name: String) throws -> Int { try f.fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(name)") ?? -1 } }

    @Test func aNewCapturesTextIsSearchableAtOnceAndReadingAgainReplacesIt() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        let first = try await service(f).search(SearchQuery(text: "elsewhere"))
        #expect(first.captures.map(\.id) == [image])
        let again = [RecognisedLine(n: 1, text: "Quarterly planning", box: PixelBox(x: 100, y: 100, width: 300, height: 30), confidence: 0.9)]
        try OCRStore(database: f.database).save(imageID: image, lines: again, durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_791_950_000))
        let old = try await service(f).search(SearchQuery(text: "elsewhere")), fresh = try await service(f).search(SearchQuery(text: "quarterly"))
        #expect(old.captures.isEmpty && fresh.captures.map(\.id) == [image])
    }

    @Test func retentionRemovesTheTextOfOldCapturesAndKeepsTheItemsTheUserEdited() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        _ = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        let item = try #require(try f.fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") })
        try f.fixture.write { try $0.execute(sql: "UPDATE items SET user_touched = 1 WHERE id = ?", arguments: [item]) }
        #expect(try await service(f).search(SearchQuery(text: "elsewhere")).captures.count == 1)
        _ = try cleanup(f, now: Date(timeIntervalSince1970: 1_800_000_000 + 100 * 86_400)).delete(olderThanDays: 30)
        let text = try await service(f).search(SearchQuery(text: "elsewhere")), kept = try await service(f).search(SearchQuery(text: "standup"))
        #expect(text.captures.isEmpty && kept.items.map(\.id) == [item])
        #expect(try table(f, "search_captures") == 0)
    }

    @Test func deleteEverythingLeavesNoCaptureTextAndNoRowForAnItemThatWentWithIt() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        _ = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        _ = try cleanup(f, now: Date(timeIntervalSince1970: 1_800_200_000)).delete(olderThanDays: nil)
        #expect(try table(f, "search_captures") == 0 && table(f, "search_items") == 0 && table(f, "items") == 0)
        #expect(try await service(f).search(SearchQuery(text: "standup")) .items.isEmpty)
    }

    @Test func theIndexSurvivesARestart() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Café - Pruebas", aliases: ["Pruebas Café"])
        let paths = AppPaths(root: f.temp.url.appendingPathComponent("Memorri"))
        guard case .opened(let reopened) = try StorageDatabase.open(paths: paths) else { Issue.record("not reopened"); return }
        let hits = try await SearchService(database: reopened).search(SearchQuery(text: "cafe pru")).items
        #expect(hits.map(\.id) == ["a"])
        #expect(try SearchIndex(database: reopened).state() == .preparing(done: 0, total: 1) || SearchIndex(database: reopened).state() == .ready)
    }
}
