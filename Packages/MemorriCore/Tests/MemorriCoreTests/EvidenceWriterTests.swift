import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct EvidenceWriterTests {
    @Test func everySightingGetsACutOutAroundItsCitedLines() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1, 2])])
        #expect(await f.writer().write(imageID: image) == 1)
        let row = try #require(try f.evidenceRows(imageID: image).first)
        let expected = try #require(EvidenceGeometry.region(lines: EvidenceFixture.lines.prefix(2).map(\.box), pictureWidth: 1200, pictureHeight: 600))
        let region = try JSONDecoder().decode(PixelRegion.self, from: Data((row["region_json"] as String).utf8))
        #expect(region == expected)
        let path = try #require(row["file_path"] as String?)
        #expect(path.hasPrefix("evidence/") && path.hasSuffix("\(row["id"] as String).heic"))
        let size = try #require(f.decodedSize(path))
        #expect(size.0 == expected.width && size.1 == expected.height)
        #expect(f.mode(path) == 0o600)
        let fileBytes = try #require(try FileManager.default.attributesOfItem(atPath: f.paths.root.appendingPathComponent(path).path)[.size] as? NSNumber)
        #expect(row["bytes"] as Int == fileBytes.intValue && (row["reason"] as String?) == nil)
        #expect(row["title"] as String == "Daily standup" && row["display_name"] as String? == "Test display")
        #expect(row["sighting_id"] as String? != nil && row["cited_lines_json"] as String == "[1,2]")
    }

    @Test func aCutOutDoesNotContainLinesTheSightingDidNotCite() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let row = try #require(try f.evidenceRows(imageID: image).first)
        let region = try JSONDecoder().decode(PixelRegion.self, from: Data((row["region_json"] as String).utf8))
        let far = EvidenceFixture.lines[2].box
        #expect(region.x + region.width <= far.x && region.y + region.height <= far.y)       // the far line is outside
        let near = EvidenceFixture.lines[0].box
        #expect(region.x <= near.x && region.y <= near.y && region.x + region.width >= near.x + near.width)
    }

    @Test func aSightingThatCitedNoLinesGetsARowWithAReasonAndNoFile() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [])])
        #expect(await f.writer().write(imageID: image) == 0)
        let row = try #require(try f.evidenceRows(imageID: image).first)
        #expect(row["reason"] as String? == "no-lines" && row["file_path"] as String? == nil && row["bytes"] as Int == 0)
    }

    @Test func aMissingPictureGetsRowsThatSayThePictureIsMissing() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        try f.fixture.base.captures.markMissing(imageID: image)
        #expect(await f.writer().write(imageID: image) == 0)
        let row = try #require(try f.evidenceRows(imageID: image).first)
        #expect(row["reason"] as String? == "picture-missing" && row["file_path"] as String? == nil)
    }

    @Test func writingAgainReplacesThePicturesEvidenceAndItsFiles() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        await f.writer().write(imageID: image)
        let first = try #require(try f.evidenceRows(imageID: image).first?["file_path"] as String?)
        // reanalysis: the sightings are replaced, then the evidence is written again
        try await f.see([f.fixture.finding("Daily standup", cited: [1, 2])], imageID: image)
        #expect(await f.writer().write(imageID: image) == 1)
        let rows = try f.evidenceRows(imageID: image)
        #expect(rows.count == 1)
        #expect(!f.fileExists(first))
        #expect(f.fileExists(try #require(rows[0]["file_path"] as String?)))
        #expect(rows[0]["cited_lines_json"] as String == "[1,2]")
    }

    @Test func anEncoderFailureIsSwallowedAndRecorded() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let image = try await f.see([f.fixture.finding("Daily standup", cited: [1])])
        #expect(await f.writer(encoder: FailingEncoder()).write(imageID: image) == 0)
        let row = try #require(try f.evidenceRows(imageID: image).first)
        #expect(row["reason"] as String? == "failed" && row["file_path"] as String? == nil)
    }

    @Test func aPictureWithNoSightingsWritesNothing() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        #expect(await f.writer().write(imageID: f.fixture.base.imageID) == 0)
        #expect(try f.evidenceRows().isEmpty)
    }

    @Test func aWideRegionIsSavedAtMostSixteenHundredPixelsWide() async throws {
        let f = try EvidenceFixture(); defer { f.cleanUp() }
        let wide = [RecognisedLine(n: 1, text: "Month row", box: PixelBox(x: 0, y: 100, width: 1200, height: 30), confidence: 0.9)]
        let image = try await f.see([f.fixture.finding("Month row", cited: [1])], lines: wide)
        await f.writer().write(imageID: image)
        let path = try #require(try f.evidenceRows(imageID: image).first?["file_path"] as String?)
        #expect(try #require(f.decodedSize(path)).0 <= EvidenceGeometry.maxWidth)
    }
}
