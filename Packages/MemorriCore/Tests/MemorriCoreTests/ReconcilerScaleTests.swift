import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Months of use: thousands of items over many contexts must not slow a capture down (SC-006, research R5).
@Suite struct ReconcilerScaleTests {
    @Test func aBigCaptureIsPlannedQuicklyAmongFiveThousandItemsInTwentyContexts() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let contexts = (0..<20).map { "ctx\($0)" }
        for id in contexts { try fixture.addContext(id, "Customer \(id)") }
        let words = ["review", "planning", "sync", "standup", "workshop", "interview", "demo", "retro", "training", "lunch"]
        let topics = ["budget", "design", "release", "hiring", "security", "roadmap", "support", "sales", "platform", "mobile"]
        let first = ReconcileFixture.nine
        try fixture.write { db in
            for n in 0..<5000 {
                let context = contexts[n % 20], day = (n / 20) % 100, slot = n % 8
                let title = "\(topics[(n / 7) % 10]) \(words[(n / 3) % 10]) \(n)"
                let start = first.addingTimeInterval(Double(day) * 86400 + Double(slot) * 3600)
                var item = Item.sample(id: "item\(n)", title: title, start: start, contextID: context)
                item.end = start.addingTimeInterval(3600)
                try ItemStore.insert(db, item, at: start)
                try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES (?, ?, ?)",
                               arguments: [item.id, TitleNormaliser.normalise(title), title])
            }
        }
        // 250 findings on the same ten days, in one context: some are old events again, most are new
        let findings = (0..<250).map { n -> Finding in
            let day = n % 10, slot = n % 8
            let start = first.addingTimeInterval(Double(day) * 86400 + Double(slot) * 3600)
            let title = n % 5 == 0 ? "\(topics[(n / 7) % 10]) \(words[(n / 3) % 10]) \(n * 20)" : "New thing number \(n)"
            return fixture.finding(title, start: start, end: start.addingTimeInterval(3600), id: "f\(n)")
        }
        try fixture.save(findings, contextID: "ctx0")
        let reconciler = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_791_999_000) })
        let clock = ContinuousClock()
        let started = clock.now
        let plan = try await reconciler.plan(imageID: fixture.base.imageID)
        let planned = started.duration(to: clock.now)
        #expect(plan.steps.count == 250)
        #expect(planned < .seconds(2), "planning 250 findings took \(planned)")
        let summary = await reconciler.reconcile(imageID: fixture.base.imageID)
        #expect(summary.error == nil)
        #expect(try fixture.count("sightings") == 250)
    }
}
