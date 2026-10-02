import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// One quiet notice per burst of new items (spec 010 FR-009 to FR-013).
@Suite struct NewItemsNotifierTests {
    final class Shower: NoticeShowing, @unchecked Sendable {
        private let lock = NSLock()
        private var _notices: [Notice] = []
        var notices: [Notice] { lock.withLock { _notices } }
        func show(_ notice: Notice) async { lock.withLock { _notices.append(notice) } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private func fixture(titles: [String], reviewing: Set<String> = [], status: [String: String] = [:], cancelled: Set<String> = []) throws -> (ReconcileFixture, [String: String]) {
        let f = try ReconcileFixture()
        var ids: [String: String] = [:]
        try f.write { db in
            for title in titles {
                let id = UUID().uuidString
                ids[title] = id
                try db.execute(sql: """
                    INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at, needs_review, review_reasons_json)
                    VALUES (?, 'appointment', 'event', ?, ?, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'), ?, ?)
                    """, arguments: [id, status[title] ?? "active", title, reviewing.contains(title) ? 1 : 0, cancelled.contains(title) ? #"["possibly-cancelled"]"# : "[]"])
            }
        }
        return (f, ids)
    }

    private func notifier(_ f: ReconcileFixture, _ shower: Shower, enabled: Flag = Flag(true), quiet: Duration = .milliseconds(60), ceiling: Duration = .milliseconds(400)) -> NewItemsNotifier {
        NewItemsNotifier(database: f.database, quiet: quiet, ceiling: ceiling, enabled: { enabled.on }, shower: shower)
    }

    private func wait(_ seconds: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aBurstOfCapturesGivesOneNoticeWithTheTotals() async throws {
        let (f, ids) = try fixture(titles: ["A", "B", "C", "D"], reviewing: ["B"]); defer { f.cleanUp() }
        let shower = Shower()
        let n = notifier(f, shower)
        await n.itemsCreated([ids["A"]!, ids["B"]!])
        try await Task.sleep(for: .milliseconds(20))
        await n.itemsCreated([ids["C"]!])
        await n.itemsCreated([ids["D"]!])
        await wait { !shower.notices.isEmpty }
        try await Task.sleep(for: .milliseconds(250))                                     // no second notice follows
        #expect(shower.notices == [Notice(newItems: 4, needReview: 1, possiblyCancelled: 0)])
        #expect(shower.notices.first?.text == "4 new items, 1 needs review")
    }

    @Test func aLongBurstIsNotHeldBackForever() async throws {
        let (f, ids) = try fixture(titles: (0..<10).map { "I\($0)" }); defer { f.cleanUp() }
        let shower = Shower()
        let n = notifier(f, shower, quiet: .milliseconds(150), ceiling: .milliseconds(300))
        // A new item every 60 ms keeps the quiet period from ever ending; the ceiling still fires.
        for index in 0..<10 { await n.itemsCreated([ids["I\(index)"]!]); try await Task.sleep(for: .milliseconds(60)) }
        await wait { !shower.notices.isEmpty }
        #expect(!shower.notices.isEmpty && shower.notices[0].newItems < 10)
    }

    @Test func nothingIsShownWhenOffWhenEmptyOrForItemsGoneByTheTime() async throws {
        let (f, ids) = try fixture(titles: ["A", "B"], status: ["B": "dismissed"]); defer { f.cleanUp() }
        let shower = Shower(), flag = Flag(false)
        let n = notifier(f, shower, enabled: flag)
        await n.itemsCreated([ids["A"]!])                                                 // switched off: ignored at once
        try await Task.sleep(for: .milliseconds(200))
        #expect(shower.notices.isEmpty)
        flag.on = true
        await n.itemsCreated([])                                                          // nothing created
        await n.itemsCreated([ids["B"]!])                                                 // dismissed meanwhile
        try await Task.sleep(for: .milliseconds(250))
        #expect(shower.notices.isEmpty)
        // Switched off between the arrival and the notice: nothing is shown either.
        await n.itemsCreated([ids["A"]!])
        flag.on = false
        try await Task.sleep(for: .milliseconds(250))
        #expect(shower.notices.isEmpty)
    }

    @Test func itemsThatBecamePossiblyCancelledAreAnnouncedAndCountAmongThoseNeedingReview() async throws {
        let (f, ids) = try fixture(titles: ["Old meeting", "New one"], reviewing: ["Old meeting"], cancelled: ["Old meeting"]); defer { f.cleanUp() }
        let shower = Shower()
        let n = notifier(f, shower)
        await n.itemsFlagged([ids["Old meeting"]!])
        await wait { !shower.notices.isEmpty }
        #expect(shower.notices == [Notice(newItems: 0, needReview: 0, possiblyCancelled: 1)])
        #expect(shower.notices.first?.text == "1 possibly cancelled")
        let (g, more) = try fixture(titles: ["X", "Y"], reviewing: ["Y"], cancelled: ["Y"]); defer { g.cleanUp() }
        let second = Shower()
        let m = notifier(g, second)
        await m.itemsCreated([more["X"]!, more["Y"]!]); await m.itemsFlagged([more["Y"]!])
        await wait { !second.notices.isEmpty }
        #expect(second.notices.first?.text == "2 new items, 1 needs review, 1 possibly cancelled")
    }

    @Test func theWordsUseSingularAndPluralForms() {
        #expect(NotificationWords.text(new: 1, needReview: 0, cancelled: 0) == "1 new item")
        #expect(NotificationWords.text(new: 3, needReview: 1, cancelled: 0) == "3 new items, 1 needs review")
        #expect(NotificationWords.text(new: 3, needReview: 2, cancelled: 0) == "3 new items, 2 need review")
        #expect(NotificationWords.text(new: 0, needReview: 0, cancelled: 2) == "2 possibly cancelled")
        #expect(NotificationWords.text(new: 0, needReview: 0, cancelled: 0).isEmpty)
    }

    @Test func theSettingIsOnByDefaultAndRemembered() {
        let settings = NotificationSettings(store: FakeSettingsStore())
        #expect(settings.enabled)
        settings.enabled = false
        #expect(!settings.enabled)
    }
}
