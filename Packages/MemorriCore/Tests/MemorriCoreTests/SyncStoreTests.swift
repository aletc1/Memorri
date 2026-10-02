import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// The user's sync choices, the link of each item and the kept runs (spec 009).
@Suite struct SyncStoreTests {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func make() throws -> (ReconcileFixture, SyncStore) {
        let fixture = try ReconcileFixture()
        try fixture.write { try $0.execute(sql: """
            INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
            VALUES ('i1', 'appointment', 'event', 'active', 'Standup', 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
            """) }
        return (fixture, SyncStore(database: fixture.database, settings: FakeSettingsStore()))
    }

    private func link(_ id: String = "i1", ek: String = "E1", state: SyncLinkState = .synced) -> SyncLink {
        let entry = RenderedEntry.sample(.event)
        return SyncLink(itemID: id, kind: .event, ekID: ek, containerID: "cal", hash: SyncRender.hash(entry), hashVersion: SyncRender.hashVersion, fields: entry, state: state, syncedAt: clock)
    }

    @Test func theChoicesDefaultToOffWithNothingChosenAndAreRemembered() throws {
        let (fixture, store) = try make(); defer { fixture.cleanUp() }
        #expect(!store.enabled && store.calendarID == nil && store.listID == nil && !store.firstSyncConfirmed)
        store.setEnabled(true); store.setCalendarID("cal"); store.setListID("list"); store.setFirstSyncConfirmed(true)
        #expect(store.enabled && store.calendarID == "cal" && store.listID == "list" && store.firstSyncConfirmed)
        store.setCalendarID(nil)
        #expect(store.calendarID == nil && store.syncSettings(now: clock) == SyncSettings(calendarID: nil, listID: "list", now: clock))
    }

    @Test func aLinkIsSavedReadBackAndReplacedByTheNextSave() throws {
        let (fixture, store) = try make(); defer { fixture.cleanUp() }
        try store.save(link(), at: clock)
        let back = try #require(try store.link(itemID: "i1"))
        #expect(back == link() && store.isLinked(ekID: "E1") && !store.isLinked(ekID: "E2"))
        var changed = link(ek: "E2", state: .failed); changed.failure = "boom"
        try store.save(changed, at: clock.addingTimeInterval(10))
        #expect(try store.links().count == 1 && store.link(itemID: "i1") == changed && !store.isLinked(ekID: "E1"))
    }

    @Test func syncAgainForgetsTheLinkAndTheLinkGoesWithItsItem() throws {
        let (fixture, store) = try make(); defer { fixture.cleanUp() }
        try store.save(link(state: .removedByUser), at: clock)
        try store.syncAgain(itemID: "i1")
        #expect(try store.link(itemID: "i1") == nil)
        try store.save(link(), at: clock)
        try fixture.write { try $0.execute(sql: "DELETE FROM items WHERE id = 'i1'") }
        #expect(try store.links().isEmpty)
    }

    @Test func onlyTheLastTwentyRunsAreKeptNewestFirst() throws {
        let (fixture, store) = try make(); defer { fixture.cleanUp() }
        for n in 0..<25 {
            var run = SyncRunRecord(startedAt: clock.addingTimeInterval(Double(n)), finishedAt: clock.addingTimeInterval(Double(n) + 1), preview: n % 2 == 0)
            run.created = n; run.detail = ["note \(n)"]
            try store.record(run)
        }
        let runs = try store.runs()
        #expect(runs.count == 20 && runs.first?.created == 24 && runs.last?.created == 5)
        #expect(runs.first?.detail == ["note 24"] && runs.first?.preview == true && runs[1].preview == false)
    }
}
