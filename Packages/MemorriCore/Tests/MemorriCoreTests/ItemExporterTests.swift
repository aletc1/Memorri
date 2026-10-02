import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Items leave Memorri as one readable file (spec 010 FR-016).
@Suite struct ItemExporterTests {
    private let clock = Date(timeIntervalSince1970: 1_800_100_000)

    private func export(_ f: ReconcileFixture) throws -> (json: [String: Any], count: Int, data: Data) {
        let url = f.base.temp.url.appendingPathComponent("items.json")
        let count = try ItemExporter(database: f.database).export(to: url, exportedAt: clock)
        let data = try Data(contentsOf: url)
        return (try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]), count, data)
    }

    private func library() async throws -> (ReconcileFixture, ItemOperations) {
        let f = try ReconcileFixture()
        try f.addContext("ctx-a", "Customer A")
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { clock })
        try f.save([f.finding("Daily standup", end: ReconcileFixture.minutes(30), people: ["Anna"], place: "Room 4"),
                    f.finding("Budget review", start: ReconcileFixture.minutes(180)), f.finding("Old idea", start: ReconcileFixture.minutes(300))],
                   imageID: f.base.imageID, contextID: "ctx-a")
        _ = await reconciler.reconcile(imageID: f.base.imageID)
        try OCRStore(database: f.database).save(imageID: f.base.imageID, lines: [RecognisedLine(n: 1, text: "Daily standup Room 4", box: PixelBox(x: 1, y: 1, width: 10, height: 10), confidence: 0.9)],
                                                 durationMs: 1, recogniser: "test", at: clock)
        return (f, ItemOperations(database: f.database, now: { clock }))
    }

    private func id(_ f: ReconcileFixture, _ title: String) throws -> String {
        try #require(try f.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = ?", arguments: [title]) })
    }

    @Test func everyItemIncludingDismissedOnesIsWrittenWithItsFieldsSightingsAndEdits() async throws {
        let (f, ops) = try await library(); defer { f.cleanUp() }
        let standup = try id(f, "Daily standup")
        _ = try ops.edit(standup, field: .place, value: .string("Room 9"))
        _ = try ops.dismiss(try id(f, "Old idea"))
        let result = try export(f)
        #expect(result.count == 3)
        #expect(result.json["format"] as? Int == 1)
        let items = try #require(result.json["items"] as? [[String: Any]])
        #expect(items.count == 3 && Set(items.compactMap { $0["title"] as? String }) == ["Daily standup", "Budget review", "Old idea"])
        let entry = try #require(items.first { $0["title"] as? String == "Daily standup" })
        #expect(entry["place"] as? String == "Room 9" && entry["context"] as? String == "Customer A" && (entry["lockedFields"] as? [String]) == ["place"])
        #expect((entry["people"] as? [String]) == ["Anna"] && entry["status"] as? String == "active")
        let sightings = try #require(entry["sightings"] as? [[String: Any]])
        #expect(sightings.count == 1 && sightings[0]["title"] as? String == "Daily standup")
        #expect(items.first { $0["title"] as? String == "Old idea" }?["status"] as? String == "dismissed")
    }

    @Test func theFileHoldsNoPicturesAndRoundTripsThroughJSON() async throws {
        let (f, _) = try await library(); defer { f.cleanUp() }
        let result = try export(f)
        let text = String(decoding: result.data, as: UTF8.self)
        #expect(!text.contains(".heic") && !text.contains("captures/") && !text.contains("evidence/"))
        let decoded = try JSONDecoder.exportDecoder.decode(ItemExportFile.self, from: result.data)
        #expect(decoded.items.count == 3 && decoded.exportedAt == clock)
    }

    @Test func aFailedWriteLeavesNoFileBehind() async throws {
        let (f, _) = try await library(); defer { f.cleanUp() }
        let missing = f.base.temp.url.appendingPathComponent("no-such-folder/items.json")
        #expect(throws: (any Error).self) { try ItemExporter(database: f.database).export(to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
