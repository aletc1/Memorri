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
}
