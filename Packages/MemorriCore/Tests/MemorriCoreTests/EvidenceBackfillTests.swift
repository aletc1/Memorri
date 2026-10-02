import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct EvidenceBackfillTests {
    private func itemID(_ f: EvidenceFixture) throws -> String { try #require(try f.fixture.read { try String.fetchOne($0, sql: "SELECT id FROM items LIMIT 1") }) }

    @Test func backfillWritesCutOutsForSightingsThatHaveNone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        try await f.see([f.fixture.finding("Daily standup", cited: [1, 2])])        // an analysis from before spec 006: no evidence
        #expect(try f.evidenceRows().isEmpty)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 1)
        let row = try #require(try f.evidenceRows().first)
        #expect(row["file_path"] as String? != nil && row["reason"] as String? == nil)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 0)               // idempotent
        #expect(try f.evidenceRows().count == 1)
    }

    @Test func backfillSkipsSightingsWhosePictureIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        try f.fixture.base.captures.markMissing(imageID: image)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 0)
        #expect(try f.evidenceRows().isEmpty)
    }

    @Test func backfillKeepsTheEvidenceTheItemAlreadyHas() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let first = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: first)
        let before = try f.evidenceRows().map { $0["id"] as String }
        let second = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_800_100_000))
        try await f.see([f.fixture.finding("Daily standup", cited: [1])], imageID: second)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 1)
        let after = try f.evidenceRows().map { $0["id"] as String }
        #expect(after.count == 2 && before.allSatisfy(after.contains))
    }

    @Test func theLaunchPassHandlesAtMostTheLimitNewestFirst() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        var images: [String] = []
        for index in 0..<3 {
            let id = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_800_100_000 + Double(index) * 86_400))
            try await f.see([f.fixture.finding("Meeting \(index)", cited: [1])], imageID: id)
            images.append(id)
        }
        #expect(await f.writer().backfill(limit: 2) == 2)
        let done = Set(try f.evidenceRows().map { $0["image_id"] as String })
        #expect(done == [images[2], images[1]])
        #expect(await f.writer().backfill(limit: 2) == 1)
        #expect(try f.evidenceRows().count == 3)
    }

    // MARK: cut-outs of an older shape (geometry version)

    /// Makes the cut-outs look like the ones written before the context was added.
    private func makeOld(_ f: EvidenceFixture) throws {
        try f.fixture.write { try $0.execute(sql: "UPDATE evidence SET geometry = 1") }
    }

    @Test func aCutOutOfAnOlderShapeIsMadeAgainWhileItsPictureIsStored() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        try makeOld(f)
        let old = try #require(try f.evidenceRows().first)
        let oldPath = try #require(old["file_path"] as String?)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 1)
        let rows = try f.evidenceRows()
        let row = try #require(rows.first)
        #expect(rows.count == 1 && row["id"] as String != old["id"] as String && row["geometry"] as Int == EvidenceGeometry.version)
        let newPath = try #require(row["file_path"] as String?)
        #expect(!f.fileExists(oldPath) && f.fileExists(newPath))
        let region = try JSONDecoder().decode(PixelRegion.self, from: Data((row["region_json"] as String).utf8))
        #expect(region.width >= 600 && region.height >= 210)                      // half of 1200 and 35% of 600
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 0)           // made once
    }

    @Test func anOlderCutOutIsKeptWhenItsPictureIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        try makeOld(f)
        let before = try #require(try f.evidenceRows().first)
        try f.fixture.base.captures.markMissing(imageID: image)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 0)
        let after = try #require(try f.evidenceRows().first)
        let keptPath = try #require(after["file_path"] as String?)
        #expect(after["id"] as String == before["id"] as String && f.fileExists(keptPath))
    }

    @Test func theLaunchPassMakesOlderCutOutsAgainWithinTheLimit() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        for index in 0..<3 {
            let id = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_800_100_000 + Double(index) * 86_400))
            try await f.see([f.fixture.finding("Meeting \(index)", cited: [1])], imageID: id)
            await f.writer().write(imageID: id)
        }
        try makeOld(f)
        #expect(await f.writer().backfill(limit: 2) == 2)
        let versions = try f.evidenceRows().map { $0["geometry"] as Int }.sorted()
        #expect(versions == [1, EvidenceGeometry.version, EvidenceGeometry.version])
    }

    @Test func aVersionTwoCutOutOfAFindingWithAWindowIsMadeAgainAsTheWindowAndKeptWhenThePictureIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let frame = PixelBox(x: 50, y: 40, width: 700, height: 400)
        let image = try await f.see([f.windowed(f.fixture.finding("Daily standup", cited: [1]), key: "w0")],
                                    windows: [f.window("w0", app: "Calendar", title: "Week", frame: frame)])
        await f.writer().write(imageID: image)
        try f.fixture.write { try $0.execute(sql: "UPDATE evidence SET geometry = 2, region_json = '{\"x\":0,\"y\":10,\"width\":600,\"height\":210}'") }
        // the picture is gone: the version 2 cut-out stays as it is
        try f.fixture.base.captures.markMissing(imageID: image)
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 0)
        #expect(try #require(try f.evidenceRows().first)["geometry"] as Int == 2)
        // the picture is stored again: the cut-out is made again, as the window
        try f.fixture.write { try $0.execute(sql: "UPDATE capture_images SET missing = 0") }
        #expect(await f.writer().backfill(itemID: try itemID(f)) == 1)
        let row = try #require(try f.evidenceRows().first)
        #expect(row["geometry"] as Int == EvidenceGeometry.version)
        #expect(try JSONDecoder().decode(PixelRegion.self, from: Data((row["region_json"] as String).utf8)) == PixelRegion(x: 50, y: 40, width: 700, height: 400))
        #expect(row["window_app"] as String? == "Calendar")
    }
}
