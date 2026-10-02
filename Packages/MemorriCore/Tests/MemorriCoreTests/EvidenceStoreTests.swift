import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct EvidenceStoreTests {
    @Test func evidenceListsNewestFirstWithTheCopiedDetails() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let older = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_791_000_000))
        let newer = try f.addStoredPicture(at: Date(timeIntervalSince1970: 1_791_500_000))
        for id in [older, newer] { try await f.see([f.fixture.finding("Daily standup", cited: [1])], imageID: id) }
        for id in [older, newer] { await f.writer().write(imageID: id) }
        let item = try #require(try ItemStore(database: f.database).items(status: [.active], kinds: nil, contextID: nil).first)
        #expect(item.sightingCount == 2)
        let records = try f.store().evidence(itemID: item.item.id)
        #expect(records.map(\.imageID) == [newer, older])
        #expect(records[0].title == "Daily standup" && records[0].citedLines == [1] && records[0].displayName == "Test display")
        #expect(records[0].capturedAt == Date(timeIntervalSince1970: 1_791_500_000) && records[0].region != nil && records[0].reason == nil)
    }

    @Test func theSavedImageIsReadBackAndIsNilWhenItsFileIsGone() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let record = try #require(try f.store().evidence(itemID: try itemID(f)).first)
        let cutOut = try #require(f.store().image(record))
        #expect(cutOut.width == record.region?.width && cutOut.height == record.region?.height)
        try FileManager.default.removeItem(at: f.paths.root.appendingPathComponent(try #require(record.filePath)))
        #expect(f.store().image(record) == nil)
    }

    @Test func theWholeCaptureComesWithItsLinesAndIsNilOnceThePictureIsMissing() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let record = try #require(try f.store().evidence(itemID: try itemID(f)).first)
        let whole = try #require(try f.store().capture(record))
        #expect(whole.picture.width == 1200 && whole.lines.map(\.n) == [1, 2, 3])
        try f.fixture.base.captures.markMissing(imageID: image)
        #expect(try f.store().capture(record) == nil)
        #expect(f.store().image(record) != nil)             // the cut-out stays
    }

    @Test func totalBytesSumsTheRows() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        #expect(try f.store().totalBytes() == 0)
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let bytes = try #require(try f.evidenceRows().first?["bytes"] as Int?)
        let total = try f.store().totalBytes()
        #expect(bytes > 0 && total == Int64(bytes))
    }

    private func itemID(_ f: EvidenceFixture) throws -> String {
        try #require(try ItemStore(database: f.database).items(status: [.active], kinds: nil, contextID: nil).first).item.id
    }
}
