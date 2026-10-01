import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct OperationLogTests {
    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
    }

    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], picture: String? = nil, offset: Int = 1) async throws -> String {
        let id = try picture ?? fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 3600))
        try fixture.save(findings, imageID: id)
        let summary = await reconciler(fixture).reconcile(imageID: id)
        #expect(summary.error == nil)
        return id
    }

    private func ops(_ fixture: ReconcileFixture, kind: OperationKind? = nil) throws -> [OperationRecord] {
        try fixture.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM reconcile_ops ORDER BY created_at, rowid").compactMap { try OperationLog.fetch(db, id: $0) }
        }.filter { kind == nil || $0.kind == kind }
    }

    @Test func recordWritesTheOperationWithOneRowPerItem() throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let state = ItemState(status: "active", mergedInto: nil, userTouched: false, locks: ["title": "o1"], observations: ["o1"])
        let at = Date(timeIntervalSince1970: 1_800_000_500)
        let id = try fixture.write { db in
            try OperationLog.record(db, kind: .merge, byUser: true, items: ["a", "b", "a"],
                                    moved: [MovedSighting(sighting: "s1", from: "b", to: "a")], before: ["b": state],
                                    detail: ["note": .string("kept the user's value")], at: at)
        }
        let record = try #require(try OperationLog(database: fixture.database).operation(id: id))
        #expect(record.kind == .merge && record.byUser && record.createdAt == at && record.undoneBy == nil)
        #expect(record.itemIDs == ["a", "b"])
        #expect(record.moved == [MovedSighting(sighting: "s1", from: "b", to: "a")])
        #expect(record.before == ["b": state])
        #expect(record.detail == ["note": .string("kept the user's value")])
        #expect(try fixture.count("reconcile_op_items") == 2)
        #expect(try OperationLog(database: fixture.database).operation(id: "nobody") == nil)
    }

    @Test func opsForAnItemComeNewestFirstThroughTheIndex() throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let ids: [String] = try fixture.write { db in
            var made: [String] = []
            for n in 1...3 {
                let kind: OperationKind = n == 2 ? .autoMerge : .edit
                let items: [String] = n == 3 ? ["a", "b"] : ["a"]
                let at = Date(timeIntervalSince1970: 1_800_000_000 + Double(n))
                made.append(try OperationLog.record(db, kind: kind, byUser: n != 2, items: items, at: at))
            }
            return made
        }
        let log = OperationLog(database: fixture.database)
        #expect(try log.ops(forItem: "a").map(\.id) == ids.reversed())
        #expect(try log.ops(forItem: "b").map(\.id) == [ids[2]])
        #expect(try log.ops(forItem: "a").map(\.byUser) == [true, false, true])
        #expect(try log.ops(forItem: "nobody").isEmpty)
    }

    @Test func aStateCapturesStatusLocksAndTheUsersOwnObservations() throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "i1"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "INSERT INTO observations VALUES ('mine', 'i1', NULL, 'title', '\"x\"', 'user', 1, datetime('now'))")
            try db.execute(sql: "INSERT INTO field_locks VALUES ('i1', 'title', 'mine', datetime('now'))")
        }
        let state = try fixture.read { try OperationLog.state($0, itemID: "i1") }
        #expect(state == ItemState(status: "active", mergedInto: nil, userTouched: false, locks: ["title": "mine"], observations: ["mine"]))
        #expect(try fixture.read { try OperationLog.state($0, itemID: "nobody") } == nil)
    }

    @Test func aPictureThatJoinsItemsOthersShowedWritesOneAutoMergeForAllOfThem() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let a = fixture.finding("Daily standup"), b = fixture.finding("Design review", start: ReconcileFixture.minutes(120))
        _ = try await see(fixture, [a, b], picture: fixture.base.imageID)
        #expect(try ops(fixture).isEmpty)                       // nothing joined: no operation
        _ = try await see(fixture, [fixture.finding("Daily standup"), fixture.finding("Design review", start: ReconcileFixture.minutes(120)),
                                    fixture.finding("Brand new", start: ReconcileFixture.minutes(300))])
        let merges = try ops(fixture, kind: .autoMerge)
        #expect(merges.count == 1)
        let merge = try #require(merges.first)
        #expect(!merge.byUser && merge.moved.count == 2 && merge.itemIDs.count == 2)
        #expect(merge.moved.allSatisfy { $0.from == nil })
        #expect(try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sightings WHERE id IN (\(merge.moved.map { "'\($0.sighting)'" }.joined(separator: ",")))") } == 2)
    }

    @Test func aReanalysisThatPutsFindingsBackWhereTheyWereWritesNoNewOperation() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        _ = try await see(fixture, [fixture.finding("Daily standup")], picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Daily standup")])
        #expect(try ops(fixture, kind: .autoMerge).count == 1)
        _ = try await see(fixture, [fixture.finding("Daily standup")], picture: second)
        #expect(try ops(fixture, kind: .autoMerge).count == 1)
    }
}
