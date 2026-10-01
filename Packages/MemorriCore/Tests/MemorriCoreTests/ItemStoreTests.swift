import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ItemStoreTests {
    private func store(_ fixture: PipelineFixture) -> ItemStore { ItemStore(database: fixture.database) }

    private func addContext(_ fixture: PipelineFixture, _ id: String, _ name: String) throws {
        try fixture.database.pool.write {
            try $0.execute(sql: "INSERT INTO contexts (id, name, timezone, created_at, updated_at) VALUES (?, ?, NULL, datetime('now'), datetime('now'))",
                           arguments: [id, name])
        }
    }

    @Test func anItemRoundTripsThroughItsRow() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try addContext(fixture, "c1", "Customer A")
        let start = Date(timeIntervalSince1970: 1_791_961_200)
        let item = Item(id: "i1", kind: .appointment, status: .active, contextID: "c1", title: "Daily standup", allDay: false, start: start,
                        end: start.addingTimeInterval(900), due: nil, remind: nil, timezone: "Europe/Madrid", dayKey: "2026-10-14",
                        people: ["Anna", "Ben"], place: "Room 4", notes: "bring notes", confidence: 0.8, userTouched: true,
                        firstSeen: Date(timeIntervalSince1970: 1_791_900_000), lastSeen: Date(timeIntervalSince1970: 1_791_950_000))
        try fixture.database.pool.write { try ItemStore.insert($0, item, at: Date(timeIntervalSince1970: 1_791_950_000)) }
        #expect(try store(fixture).item(id: "i1") == item)
        #expect(try store(fixture).item(id: "nobody") == nil)
    }

    @Test func updatingAnItemChangesItsRowAndKeepsItsCreationTime() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        var item = Item.sample(id: "i1")
        let created = Date(timeIntervalSince1970: 1_791_000_000), updated = Date(timeIntervalSince1970: 1_791_999_000)
        try fixture.database.pool.write { try ItemStore.insert($0, item, at: created) }
        item.title = "Daily sync"; item.status = .dismissed; item.place = "Room 9"
        try fixture.database.pool.write { try ItemStore.update($0, item, at: updated) }
        #expect(try store(fixture).item(id: "i1") == item)
        let row = try fixture.database.pool.read { try Row.fetchOne($0, sql: "SELECT created_at, updated_at FROM items WHERE id = 'i1'") }
        #expect(row?["created_at"] as Date? == created && row?["updated_at"] as Date? == updated)
    }

    @Test func itemsFilterByStatusFamilyAndContext() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try addContext(fixture, "c1", "A"); try addContext(fixture, "c2", "B")
        let items = [Item.sample(id: "a", kind: .appointment, contextID: "c1"),
                     Item.sample(id: "t", kind: .task, contextID: "c1"),
                     Item.sample(id: "d", kind: .reminder, contextID: "c2"),
                     Item.sample(id: "n", kind: .appointment, contextID: nil)]
        var dismissed = Item.sample(id: "x", kind: .appointment, contextID: "c1"); dismissed.status = .dismissed
        var merged = Item.sample(id: "m", kind: .appointment, contextID: "c1"); merged.status = .merged
        try fixture.database.pool.write { db in
            for item in items + [dismissed, merged] { try ItemStore.insert(db, item, at: Date(timeIntervalSince1970: 1)) }
        }
        let s = store(fixture)
        func ids(_ rows: [ItemRow]) -> Set<String> { Set(rows.map(\.item.id)) }
        #expect(ids(try s.items(status: [.active], kinds: nil, contextID: nil)) == ["a", "t", "d", "n"])
        #expect(ids(try s.items(status: [.active, .dismissed], kinds: nil, contextID: nil)) == ["a", "t", "d", "n", "x"])
        #expect(ids(try s.items(status: [.active], kinds: [.event], contextID: nil)) == ["a", "n"])
        #expect(ids(try s.items(status: [.active], kinds: [.todo], contextID: nil)) == ["t", "d"])
        #expect(ids(try s.items(status: [.active], kinds: nil, contextID: .some("c1"))) == ["a", "t"])
        #expect(ids(try s.items(status: [.active], kinds: nil, contextID: .some(nil))) == ["n"])
        #expect(ids(try s.items(status: [.merged], kinds: nil, contextID: nil)) == ["m"])
    }

    @Test func rowsCarrySightingCountsLocksAndPossibleDuplicates() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try fixture.database.pool.write { db in
            for id in ["a", "b"] { try ItemStore.insert(db, Item.sample(id: id), at: Date(timeIntervalSince1970: 1)) }
            for n in 1...2 {
                try db.execute(sql: """
                    INSERT INTO sightings (id, item_id, image_id, finding_id, captured_at, title, cited_lines_json, confidence, decision_json, created_at)
                    VALUES (?, 'a', ?, 'f', datetime('now'), 'Daily standup', '[1]', 0.8, '{}', datetime('now'))
                    """, arguments: ["s\(n)", fixture.image.id])
            }
            try db.execute(sql: "INSERT INTO observations VALUES ('o', 'a', NULL, 'title', '\"x\"', 'user', 1, datetime('now'))")
            try db.execute(sql: "INSERT INTO field_locks VALUES ('a', 'title', 'o', datetime('now'))")
            try db.execute(sql: "INSERT INTO possible_duplicates VALUES ('a', 'b', '{}', datetime('now'))")
        }
        let rows = try store(fixture).items(status: [.active], kinds: nil, contextID: nil)
        let a = try #require(rows.first { $0.item.id == "a" }), b = try #require(rows.first { $0.item.id == "b" })
        #expect(a.sightingCount == 2 && a.locked && a.possibleDuplicate)
        #expect(b.sightingCount == 0 && !b.locked && b.possibleDuplicate)
    }

    @Test func detailOfAnItemWithNoHistoryIsEmptyAndAnUnknownIdThrows() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try fixture.database.pool.write { try ItemStore.insert($0, Item.sample(id: "i1"), at: Date(timeIntervalSince1970: 1)) }
        let detail = try store(fixture).detail(itemID: "i1")
        #expect(detail.item.id == "i1" && detail.sightings.isEmpty && detail.aliases.isEmpty && detail.locks.isEmpty)
        #expect(detail.possibleDuplicates.isEmpty && detail.operations.isEmpty && detail.fields.isEmpty)
        #expect(throws: ItemStoreError.notFound) { _ = try store(fixture).detail(itemID: "nobody") }
    }

    @Test func observeItemsEmitsAgainAfterAnInsert() async throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let s = store(fixture)
        var iterator = s.observeItems(status: [.active]).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isEmpty == true)
        try await fixture.database.pool.write { try ItemStore.insert($0, Item.sample(id: "i1"), at: Date(timeIntervalSince1970: 1)) }
        let second = await iterator.next()
        #expect(second?.map(\.item.id) == ["i1"])
    }

    // MARK: detail (spec 005, user story 2)

    private func twoSightingItem(_ fixture: ReconcileFixture) async throws -> String {
        let r = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        try fixture.save([fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), inferredEnd: true, cited: [3, 4])], imageID: fixture.base.imageID)
        _ = await r.reconcile(imageID: fixture.base.imageID)
        let second = try fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_003_600), display: "Left display")
        try fixture.save([fixture.finding("Daily stand…", end: ReconcileFixture.minutes(30), confidence: 0.9, place: "Room 4", cited: [7])], imageID: second)
        _ = await r.reconcile(imageID: second)
        return try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil)[0].item.id
    }

    @Test func detailListsEveryFieldWithItsObservationsAndWhereTheyCameFrom() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await twoSightingItem(fixture)
        let detail = try ItemStore(database: fixture.database).detail(itemID: id)
        let end = try #require(detail.fields.first { $0.field == .end })
        #expect(end.current == .date(ReconcileFixture.minutes(30)) && end.entries.count == 2 && !end.locked)
        #expect(end.entries.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.inferred, .read])
        let read = try #require(end.entries.first { $0.source == .read })
        #expect(read.citedLines == [7] && read.confidence == 0.9 && read.sightingID != nil && read.imageID != nil)
        #expect(end.chosenObservationID == read.observationID)
        let inferred = try #require(end.entries.first { $0.source == .inferred })
        #expect(inferred.citedLines == [3, 4] && inferred.imageID == fixture.base.imageID)
        let place = try #require(detail.fields.first { $0.field == .place })
        #expect(place.entries.count == 1 && place.current == .string("Room 4"))
        #expect(detail.fields.first { $0.field == .notes } == nil)
    }

    @Test func detailListsTheSightingsWithCaptureDisplayTitleAndTheStoredDecision() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await twoSightingItem(fixture)
        let detail = try ItemStore(database: fixture.database).detail(itemID: id)
        #expect(detail.sightings.count == 2)
        let newest = try #require(detail.sightings.max { $0.capturedAt < $1.capturedAt })
        #expect(newest.displayName == "Left display" && newest.title == "Daily stand…" && newest.citedLines == [7])
        #expect(newest.capturedAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(newest.decisionJSON.contains("\"rule\":\"text-time\"") && newest.decisionJSON.contains("\"text\":0.95"))
        let first = try #require(detail.sightings.min { $0.capturedAt < $1.capturedAt })
        #expect(first.decisionJSON.contains("\"rule\""))
    }

    @Test func detailListsOtherTitlesLocksPossibleDuplicatesAndOperations() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let id = try await twoSightingItem(fixture)
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "other", title: "Something else"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "INSERT INTO observations VALUES ('mine', ?, NULL, 'place', '\"Room 9\"', 'user', 1, datetime('now'))", arguments: [id])
            try db.execute(sql: "INSERT INTO field_locks VALUES (?, 'place', 'mine', datetime('now'))", arguments: [id])
            let pair = [id, "other"].sorted()
            try db.execute(sql: "INSERT INTO possible_duplicates VALUES (?, ?, '{}', datetime('now'))", arguments: [pair[0], pair[1]])
            try db.execute(sql: "INSERT INTO reconcile_ops VALUES ('op1', 'edit', 1, '[]', '[]', '{}', '{}', NULL, '2030-01-02 10:00:00')")
            try db.execute(sql: "INSERT INTO reconcile_ops VALUES ('op2', 'auto_merge', 0, '[]', '[]', '{}', '{}', 'op3', '2030-01-03 10:00:00')")
            try db.execute(sql: "INSERT INTO reconcile_op_items VALUES ('op1', ?)", arguments: [id])
            try db.execute(sql: "INSERT INTO reconcile_op_items VALUES ('op2', ?)", arguments: [id])
        }
        let detail = try ItemStore(database: fixture.database).detail(itemID: id)
        #expect(detail.aliases == ["Daily stand…"])
        #expect(detail.locks == [.place: "mine"])
        #expect(detail.possibleDuplicates == ["other"])
        #expect(detail.operations.prefix(2).map(\.id) == ["op2", "op1"])
        #expect(detail.operations.prefix(2).map(\.undone) == [true, false])
        #expect(detail.operations.prefix(2).map(\.byUser) == [false, true])
        #expect(detail.operations.count == 3)          // and the automatic merge the reconciler wrote for the second sighting
        let place = try #require(detail.fields.first { $0.field == .place })
        #expect(place.locked && place.current == .string("Room 9") && place.chosenObservationID == "mine")
        #expect(place.entries.contains { $0.source == .user && $0.sightingID == nil })
    }

    // MARK: sweep after cleanups (spec 005, FR-014)

    private func eventID(_ fixture: ReconcileFixture, of imageID: String) throws -> String {
        try fixture.read { try String.fetchOne($0, sql: "SELECT event_id FROM capture_images WHERE id = ?", arguments: [imageID]) ?? "" }
    }

    @Test func sweepRecomputesTheItemsThatLostSightingsAndRemovesTheEmptyUntouchedOnes() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        try fixture.save([fixture.finding("Daily standup"), fixture.finding("Only on the second", start: ReconcileFixture.minutes(240))])
        _ = await r.reconcile(imageID: fixture.base.imageID)
        let second = try fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_003_600))
        try fixture.save([fixture.finding("Daily standup", place: "Room 4"), fixture.finding("Only here", start: ReconcileFixture.minutes(480))], imageID: second)
        _ = await r.reconcile(imageID: second)
        #expect(try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil).count == 3)

        try fixture.base.captures.deleteEvents(ids: [try eventID(fixture, of: second)])
        let removed = try ItemStore(database: fixture.database).sweep(at: Date(timeIntervalSince1970: 1_800_300_000))
        #expect(removed == 1)
        let rows = try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil)
        #expect(Set(rows.map(\.item.title)) == ["Daily standup", "Only on the second"])
        let standup = try #require(rows.first { $0.item.title == "Daily standup" })
        #expect(standup.sightingCount == 1 && standup.item.place == nil)          // the place was only on the deleted capture
        #expect(try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE field = 'place'") } == 0)
    }

    @Test func sweepKeepsEmptyItemsTheUserEditedLockedOrDismissed() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let image = try fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_003_600))
        let titles = ["Edited", "Dismissed", "Untouched"]
        try fixture.save(titles.enumerated().map { fixture.finding($1, start: ReconcileFixture.minutes($0 * 180)) }, imageID: image)
        _ = await r.reconcile(imageID: image)
        let byTitle = Dictionary(uniqueKeysWithValues: try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil)
            .map { ($0.item.title, $0.item.id) })
        let ops = ItemOperations(database: fixture.database, now: { Date(timeIntervalSince1970: 1_800_200_000) })
        try ops.edit(byTitle["Edited"]!, field: .place, value: .string("Room 9"))
        try ops.dismiss(byTitle["Dismissed"]!)
        let opsBefore = try fixture.count("reconcile_op_items")

        try fixture.base.captures.deleteEvents(ids: [try eventID(fixture, of: image)])
        let removed = try ItemStore(database: fixture.database).sweep(at: Date(timeIntervalSince1970: 1_800_300_000))
        #expect(removed == 1)
        let left = try ItemStore(database: fixture.database).items(status: [.active, .dismissed], kinds: nil, contextID: nil)
        #expect(Set(left.map(\.item.title)) == ["Edited", "Dismissed"])
        #expect(try fixture.count("reconcile_op_items") == opsBefore)                      // the history stays
        let edited = try #require(left.first { $0.item.title == "Edited" })
        #expect(edited.item.place == "Room 9" && edited.sightingCount == 0 && edited.locked)
    }

    @Test func sweepDropsCachedVectorsOfTitlesNoItemKnowsAnyMore() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "i1", title: "Daily standup"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "UPDATE items SET user_touched = 1")
            try db.execute(sql: "INSERT INTO item_aliases VALUES ('i1', 'daily standup', 'Daily standup')")
            try db.execute(sql: "INSERT INTO title_embeddings VALUES ('daily standup', 'e5', x'00', datetime('now'))")
            try db.execute(sql: "INSERT INTO title_embeddings VALUES ('daily standup', 'other', x'00', datetime('now'))")
            try db.execute(sql: "INSERT INTO title_embeddings VALUES ('long gone', 'e5', x'00', datetime('now'))")
        }
        try ItemStore(database: fixture.database).sweep(at: Date(timeIntervalSince1970: 1_800_300_000))
        let left = try fixture.read { try String.fetchAll($0, sql: "SELECT normalised || '/' || model FROM title_embeddings ORDER BY 1") }
        #expect(left == ["daily standup/e5", "daily standup/other"])
    }

    @Test func sweepOnATableWithNothingToDoChangesNothing() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        try fixture.save([fixture.finding("Daily standup", end: ReconcileFixture.minutes(30), place: "Room 4")])
        _ = await r.reconcile(imageID: fixture.base.imageID)
        let before = try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil).map(\.item)
        #expect(try ItemStore(database: fixture.database).sweep(at: Date(timeIntervalSince1970: 1_800_300_000)) == 0)
        #expect(try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil).map(\.item) == before)
    }
}
