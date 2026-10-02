import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct EvidenceLifecycleTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private func operations(_ f: EvidenceFixture) -> ItemOperations { ItemOperations(database: f.database, now: { clock }) }

    private func cleanup(_ f: EvidenceFixture, now: Date) -> CleanupService {
        CleanupService(paths: f.paths, store: f.fixture.base.captures, files: CaptureFileStore(paths: f.paths),
                       time: FakeTimeSource(now.timeIntervalSinceReferenceDate))
    }

    /// Two pictures that show "Daily standup" and "Reunión diaria" (two items, possible duplicates), each with evidence.
    private func twoItems(_ f: EvidenceFixture) async throws -> (a: String, b: String, imageB: String) {
        let first = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        let second = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_800_100_000))
        try await f.see([f.fixture.finding("Reunión diaria", cited: [1])], imageID: second)
        for id in [first, second] { await f.writer().write(imageID: id) }
        let ids = try f.fixture.read { try String.fetchAll($0, sql: "SELECT id FROM items ORDER BY first_seen, id") }
        #expect(ids.count == 2)
        return (ids[0], ids[1], second)
    }

    private func evidenceItems(_ f: EvidenceFixture) throws -> [String: Int] {
        try f.fixture.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT item_id, COUNT(*) AS n FROM evidence GROUP BY item_id").map { ($0["item_id"] as String, $0["n"] as Int) })
        }
    }

    @Test func mergeSplitAndUndoMoveEvidenceWithTheirSightings() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let (a, b, _) = try await twoItems(f)
        #expect(try evidenceItems(f) == [a: 1, b: 1])
        let merge = try operations(f).merge(a, b)
        #expect(try evidenceItems(f) == [a: 2])
        _ = try await operations(f).undo(merge)
        #expect(try evidenceItems(f) == [a: 1, b: 1])
        _ = try operations(f).merge(a, b)
        let sightingOfB = try f.fixture.read { try String.fetchOne($0, sql: "SELECT sighting_id FROM evidence WHERE image_id != ? LIMIT 1", arguments: [f.fixture.base.imageID]) }
        let split = try operations(f).split(a, sightings: [try #require(sightingOfB)])
        #expect(try evidenceItems(f) == [a: 1, split.newItem: 1])
    }

    @Test func retentionKeepsTheEvidenceAndTheItemsOwnCutOutAfterItsCaptureIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let item = try #require(try f.fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") })
        try f.fixture.write { try $0.execute(sql: "UPDATE items SET user_touched = 1 WHERE id = ?", arguments: [item]) }      // an edited item survives
        let path = try #require(try f.evidenceRows().first?["file_path"] as String?)
        let removed = try cleanup(f, now: Date(timeIntervalSince1970: 1_800_000_000 + 100 * 86_400)).delete(olderThanDays: 30)
        #expect(removed == 1)
        let rows = try f.evidenceRows()
        #expect(rows.count == 1 && (rows[0]["sighting_id"] as String?) == nil && f.fileExists(path))
        let record = try #require(try f.store().evidence(itemID: item).first)
        #expect(f.store().image(record) != nil)
        #expect(try f.store().capture(record) == nil)           // the whole capture is gone
    }

    @Test func deleteEverythingRemovesEveryEvidenceRowAndFile() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let path = try #require(try f.evidenceRows().first?["file_path"] as String?)
        try Data("stray".utf8).write(to: f.paths.root.appendingPathComponent("evidence/stray.heic"))
        #expect(try cleanup(f, now: clock).delete(olderThanDays: nil) == 1)
        let remaining = try f.evidenceRows().count
        #expect(remaining == 0 && !f.fileExists(path) && !f.fileExists("evidence/stray.heic"))
        let bytes = try f.store().totalBytes()
        #expect(bytes == 0)
    }

    @Test func anItemRemovedBySweepTakesItsEvidenceFilesWithIt() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let path = try #require(try f.evidenceRows().first?["file_path"] as String?)
        // retention deletes the capture; nobody edited the item, so the sweep removes it and its evidence
        _ = try cleanup(f, now: Date(timeIntervalSince1970: 1_800_000_000 + 100 * 86_400)).delete(olderThanDays: 30)
        #expect(try f.evidenceRows().isEmpty)
        #expect(!f.fileExists(path))
    }

    @Test func reanalysisRemovesThePicturesOldEvidenceFiles() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let old = try #require(try f.evidenceRows().first?["file_path"] as String?)
        try await f.see([f.fixture.finding("Daily standup", cited: [1, 2])], imageID: image)
        await f.writer().write(imageID: image)
        let count = try f.evidenceRows().count
        #expect(!f.fileExists(old) && count == 1)
    }

    @Test func startUpReconcileRemovesEvidenceFilesNoRowNamesAndKeepsTheRest() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let kept = try #require(try f.evidenceRows().first?["file_path"] as String?)
        let stray = "evidence/2027-01/stray.heic"
        try FileManager.default.createDirectory(at: f.paths.root.appendingPathComponent("evidence/2027-02"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.paths.root.appendingPathComponent(stray))
        try Data("x".utf8).write(to: f.paths.root.appendingPathComponent("evidence/2027-02/lonely.heic"))
        _ = try CaptureFileStore(paths: f.paths).reconcile(with: f.fixture.base.captures)
        #expect(f.fileExists(kept) && !f.fileExists(stray) && !f.fileExists("evidence/2027-02/lonely.heic"))
        #expect(!f.fileExists("evidence/2027-02"))           // the emptied month folder goes too
    }

    @Test func theDeleteEverythingPreviewCountsEvidenceBytes() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let service = cleanup(f, now: clock)
        let withEvidence = try service.preview(olderThanDays: nil).bytes
        let evidenceBytes = try f.store().totalBytes()
        try EvidenceFiles.removeAll(paths: f.paths, database: f.database)
        let without = try service.preview(olderThanDays: nil).bytes
        #expect(withEvidence - without == evidenceBytes && evidenceBytes > 0)
    }

    // MARK: window names

    @Test func theWindowNameStaysWithTheItemAfterItsCaptureIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let frame = PixelBox(x: 0, y: 0, width: 700, height: 400)
        let image = try await f.see([f.windowed(f.fixture.finding("Daily standup", cited: [1]), key: "w0")],
                                    windows: [f.window("w0", app: "Calendar", title: "Week", frame: frame)])
        await f.writer().write(imageID: image)
        let item = try #require(try f.fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items") })
        try f.fixture.write { try $0.execute(sql: "UPDATE items SET user_touched = 1 WHERE id = ?", arguments: [item]) }
        let sighting = try f.fixture.read { try Row.fetchOne($0, sql: "SELECT window_app, window_title FROM sightings") }
        #expect(sighting?["window_app"] as String? == "Calendar" && sighting?["window_title"] as String? == "Week")
        _ = try cleanup(f, now: Date(timeIntervalSince1970: 1_800_000_000 + 100 * 86_400)).delete(olderThanDays: 30)
        let record = try #require(try f.store().evidence(itemID: item).first)
        #expect(record.windowApp == "Calendar" && record.windowTitle == "Week")
        let readings = try f.fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM window_readings") ?? -1 }
        #expect(readings == 0)             // the capture's own readings went with it
    }

    @Test func deleteEverythingRemovesTheEvidenceRowsWithTheirWindowNames() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let frame = PixelBox(x: 0, y: 0, width: 700, height: 400)
        let image = try await f.see([f.windowed(f.fixture.finding("Daily standup", cited: [1]), key: "w0")],
                                    windows: [f.window("w0", app: "Calendar", title: "Week", frame: frame)])
        await f.writer().write(imageID: image)
        _ = try cleanup(f, now: clock).delete(olderThanDays: nil)
        let names = try f.fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM evidence WHERE window_app IS NOT NULL OR window_title IS NOT NULL") ?? -1 }
        #expect(names == 0)
    }
}
