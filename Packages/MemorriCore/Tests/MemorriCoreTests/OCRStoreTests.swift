import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct OCRStoreTests {
    private let when = Date(timeIntervalSinceReferenceDate: 1000)

    private func lines(_ texts: String...) -> [RecognisedLine] {
        texts.enumerated().map { i, text in
            RecognisedLine(n: i + 1, text: text, box: PixelBox(x: 10 * i, y: 20 * i, width: 100, height: 18), confidence: 0.5 + Double(i) / 10)
        }
    }

    @Test func savesTextBoxAndConfidenceUnderImageAndNumber() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, lines: lines("Team sync", "Room 4"), durationMs: 1200, recogniser: "vision-accurate-corrected", at: when)
        #expect(try store.lines(imageID: fixture.imageID) == lines("Team sync", "Room 4"))
        let read = try fixture.database.pool.read { try Row.fetchOne($0, sql: "SELECT * FROM ocr_reads WHERE image_id = ?", arguments: [fixture.imageID]) }
        #expect(read?["line_count"] as Int? == 2)
        #expect(read?["duration_ms"] as Int? == 1200)
        #expect(read?["recogniser"] as String? == "vision-accurate-corrected")
        #expect(read?["read_at"] as Date? == when)
    }

    @Test func savingTwiceLeavesOneSet() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, lines: lines("a", "b", "c"), durationMs: 1, recogniser: "r", at: when)
        try store.save(imageID: fixture.imageID, lines: lines("x", "y"), durationMs: 2, recogniser: "r", at: when)
        #expect(try store.lines(imageID: fixture.imageID).map(\.text) == ["x", "y"])
        let counts = try fixture.database.pool.read {
            (try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_lines") ?? -1, try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_reads") ?? -1)
        }
        #expect(counts.0 == 2 && counts.1 == 1)
    }

    @Test func zeroLinesStillCountsAsRead() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        #expect(try store.isRead(imageID: fixture.imageID) == false)
        try store.save(imageID: fixture.imageID, lines: [], durationMs: 300, recogniser: "r", at: when)
        #expect(try store.isRead(imageID: fixture.imageID))
        #expect(try store.lines(imageID: fixture.imageID).isEmpty)
        let count = try fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT line_count FROM ocr_reads") }
        #expect(count == 0)
    }

    @Test func linesComeBackInReadingOrderWhateverTheInsertOrder() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, lines: lines("a", "b", "c").reversed(), durationMs: 1, recogniser: "r", at: when)
        #expect(try store.lines(imageID: fixture.imageID).map(\.n) == [1, 2, 3])
    }

    @Test func anUnknownPictureIsNotReadAndHasNoLines() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        #expect(try store.isRead(imageID: "nope") == false)
        #expect(try store.lines(imageID: "nope").isEmpty)
    }

    @Test func deletingTheCaptureRemovesTheRead() throws {
        let fixture = try makePipelineFixture()
        defer { fixture.cleanUp() }
        let store = OCRStore(database: fixture.database)
        try store.save(imageID: fixture.imageID, lines: lines("a", "b"), durationMs: 1, recogniser: "r", at: when)
        try fixture.captures.deleteEvents(ids: [fixture.event.id])
        #expect(try store.isRead(imageID: fixture.imageID) == false)
        #expect(try store.lines(imageID: fixture.imageID).isEmpty)
    }
}
