import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Months of use: opening an item's evidence and the Inbox must stay immediate among thousands of items (spec 006, SC-007, FR-020).
@Suite struct EvidenceScaleTests {
    @Test func evidenceAndTheInboxStayFastAmongFiveThousandItemsAndTwentyThousandSightings() throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let paths = fixture.base.paths
        let image = fixture.base.imageID
        let first = ReconcileFixture.nine

        // Five real cut-out files for the item that is opened; the others only have rows.
        let folder = paths.evidence.appendingPathComponent("2026-10")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutOut = try makeHEICData(width: 1600, height: 400)
        for k in 0..<5 { try cutOut.write(to: folder.appendingPathComponent("opened-\(k).heic")) }

        try fixture.write { db in
            for n in 0..<5000 {
                let start = first.addingTimeInterval(Double(n % 100) * 86400 + Double(n % 8) * 3600)
                var item = Item.sample(id: n == 0 ? "opened" : "item\(n)", title: "Review number \(n)", start: start, contextID: nil)
                item.needsReview = n % 5 == 0                                   // a fifth waits in the Inbox
                item.reviewReasons = item.needsReview ? [.lowConfidence] : []
                try ItemStore.insert(db, item, at: start)
                let sightings = n == 0 ? 5 : 4
                for k in 0..<sightings {
                    let sighting = "s\(n)-\(k)"
                    let when = start.addingTimeInterval(Double(k) * 600)
                    try db.execute(sql: """
                        INSERT INTO sightings (id, item_id, image_id, finding_id, captured_at, title, cited_lines_json, confidence, decision_json, created_at)
                        VALUES (?, ?, ?, 'f', ?, 'Review', '[1]', 0.8, '{}', ?)
                        """, arguments: [sighting, item.id, image, when, when])
                    let file = n == 0 ? "evidence/2026-10/opened-\(k).heic" : "evidence/2026-10/ev-\(n)-\(k).heic"
                    try db.execute(sql: """
                        INSERT INTO evidence (id, item_id, sighting_id, image_id, captured_at, display_name, title, cited_lines_json, region_json, file_path, bytes, created_at)
                        VALUES (?, ?, ?, ?, ?, 'Display', 'Review', '[1]', '{"x":0,"y":0,"width":1600,"height":400}', ?, 1000, ?)
                        """, arguments: ["ev\(n)-\(k)", item.id, sighting, image, when, file, when])
                }
            }
        }
        #expect(try fixture.count("items") == 5000 && fixture.count("sightings") == 20001 && fixture.count("evidence") == 20001)

        // Best of three, as in `ReconcilerScaleTests`: other tests and builds may be using the machine.
        let clock = ContinuousClock()
        let evidence = EvidenceStore(database: fixture.database, paths: paths, pictures: StoredPictureProvider(paths: paths, store: fixture.base.captures))
        var bestEvidence = Duration.seconds(1000), bestInbox = Duration.seconds(1000)
        var loaded = 0, inbox = 0, count = 0
        let store = ItemStore(database: fixture.database)
        for _ in 0..<3 {
            var started = clock.now
            let records = try evidence.evidence(itemID: "opened")
            loaded = records.prefix(5).compactMap { evidence.image($0) }.count
            bestEvidence = min(bestEvidence, started.duration(to: clock.now))

            started = clock.now
            inbox = try store.items(status: [.active], kinds: nil, contextID: nil, review: true).count
            count = try store.reviewCount()
            bestInbox = min(bestInbox, started.duration(to: clock.now))
        }
        print("scale evidence best=\(bestEvidence) inbox best=\(bestInbox)")
        #expect(loaded == 5)
        #expect(inbox == 1000 && count == 1000)
        #expect(bestEvidence < .seconds(1), "opening an item's evidence took \(bestEvidence) at best")
        #expect(bestInbox < .milliseconds(500), "the Inbox and its count took \(bestInbox) at best")
    }
}
