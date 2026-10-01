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
}
