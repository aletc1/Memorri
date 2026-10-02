import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// The text of captures is searchable (spec 007, US2): one document per capture, matching lines and the window found for the page shown.
@Suite struct SearchCapturesTests {
    private func line(_ n: Int, _ text: String, x: Int = 100, y: Int? = nil) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y ?? 40 * n, width: 300, height: 30), confidence: 0.9)
    }

    private func read(_ f: ReconcileFixture, _ imageID: String, _ lines: [RecognisedLine]) throws {
        try OCRStore(database: f.database).save(imageID: imageID, lines: lines, durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func rows(_ f: ReconcileFixture) throws -> Int { try f.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_captures") ?? -1 } }

    private func window(_ imageID: String, key: String, app: String, title: String?, frame: PixelBox, visible: [PixelBox]) -> WindowReadingRecord {
        WindowReadingRecord(imageID: imageID, windowKey: key, appName: app, title: title, frame: frame, visible: visible, visibleShare: 1, relevant: true,
                            kind: .email, confidence: 0.9, remote: false, runID: nil, promptVersion: "windows-v1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func search(_ f: ReconcileFixture, _ text: String, captureLimit: Int = 20, captureOffset: Int = 0) async throws -> SearchResults {
        try await SearchService(database: f.database).search(SearchQuery(text: text), captureLimit: captureLimit, captureOffset: captureOffset)
    }

    @Test func storingTheTextWritesOneDocumentAndReadingAgainReplacesIt() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let id = f.base.imageID
        try read(f, id, [line(1, "Invoice 2291 due Friday"), line(2, "Pay to Acme")])
        #expect(try rows(f) == 1)
        let first = try await search(f, "2291")
        #expect(first.captures.map(\.id) == [id])
        try read(f, id, [line(1, "Receipt 77 paid")])
        #expect(try rows(f) == 1)
        let stale = try await search(f, "2291"), fresh = try await search(f, "receipt")
        #expect(stale.captures.isEmpty && fresh.captures.map(\.id) == [id])
    }

    @Test func aCaptureWithNoTextHasNoDocument() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try read(f, f.base.imageID, [])
        #expect(try rows(f) == 0)
        try read(f, f.base.imageID, [line(1, "   ")])
        #expect(try rows(f) == 0)
    }

    @Test func deletingTheCaptureLeavesNoText() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try read(f, f.base.imageID, [line(1, "Invoice 2291 due Friday")])
        let events = try f.read { try String.fetchAll($0, sql: "SELECT id FROM capture_events") }
        try f.base.captures.deleteEvents(ids: events)
        #expect(try rows(f) == 0)
        #expect(try await search(f, "2291").captures.isEmpty)
    }

    @Test func allTheWordsMayBeOnDifferentLines() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try read(f, f.base.imageID, [line(1, "Invoice 2291"), line(2, "nothing here"), line(3, "due on Friday")])
        let hit = try #require(try await search(f, "invoice friday").captures.first)
        #expect(hit.lines.map(\.number) == [1, 3])
        let none = try await search(f, "invoice monday")
        #expect(none.captures.isEmpty)
    }

    @Test func aResultShowsAtMostThreeLinesWithTheMostWordsMarkedInReadingOrder() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try read(f, f.base.imageID, [line(1, "budget"), line(2, "budget review notes"), line(3, "other"), line(4, "review"), line(5, "budget review"), line(6, "budget")])
        let hit = try #require(try await search(f, "budget review").captures.first)
        #expect(hit.lines.map(\.number) == [1, 2, 5])          // both-word lines 2 and 5 first, then the earliest single-word line; shown in reading order
        let second = hit.lines[1].text
        #expect(second.marks.map { String(second.text[$0]) } == ["budget", "review"])
    }

    @Test func theWindowIsTheOneWhoseVisiblePartHoldsTheLine() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let id = f.base.imageID
        try read(f, id, [line(1, "Invoice 2291", x: 100, y: 100), line(2, "Elsewhere 2291", x: 1500, y: 100)])
        try WindowReadingStore(database: f.database).save(imageID: id, readings: [
            window(id, key: "w0", app: "Mail", title: "Inbox", frame: PixelBox(x: 0, y: 0, width: 1000, height: 800), visible: [PixelBox(x: 0, y: 0, width: 1000, height: 800)]),
            window(id, key: "w1", app: "Calendar", title: "Week", frame: PixelBox(x: 0, y: 0, width: 2000, height: 800), visible: [PixelBox(x: 1000, y: 0, width: 1000, height: 800)])])
        let hit = try #require(try await search(f, "2291").captures.first)
        #expect(hit.windowApp == "Mail" && hit.windowTitle == "Inbox")                    // the first matching line is in the front window
        let second = try #require(try await search(f, "elsewhere").captures.first)
        #expect(second.windowApp == "Calendar" && second.windowTitle == "Week")
        try WindowReadingStore(database: f.database).save(imageID: id, readings: [])
        let none = try #require(try await search(f, "2291").captures.first)
        #expect(none.windowApp == nil && none.windowTitle == nil)
    }

    @Test func capturesComeNewestFirstAfterTheItemsAndPage() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        var ids = [f.base.imageID]
        for n in 1...24 { ids.append(try f.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 3600), display: "Display \(n)")) }
        for id in ids { try read(f, id, [line(1, "Invoice 2291 due")]) }
        let first = try await search(f, "invoice", captureLimit: 20)
        #expect(first.captures.count == 20 && first.moreCaptures)
        #expect(first.captures.map(\.capturedAt) == first.captures.map(\.capturedAt).sorted(by: >))
        let second = try await search(f, "invoice", captureLimit: 20, captureOffset: 20)
        #expect(second.captures.count == 5 && !second.moreCaptures)
        #expect(Set((first.captures + second.captures).map(\.id)).count == 25)
        #expect(first.captures.first?.displayName == "Display 24")
    }

    @Test func theSameWordInTwoCapturesIsTwoResultsAndTheItemTheyMadeIsListedOnce() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let other = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_100_000))
        try read(f, f.base.imageID, [line(1, "Daily standup")]); try read(f, other, [line(1, "Daily standup")])
        try await f.database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                VALUES ('i1', 'appointment', 'event', 'active', 'Daily standup', 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                """)
        }
        let results = try await search(f, "standup")
        #expect(results.items.map(\.id) == ["i1"] && results.captures.count == 2)
    }

    @Test func picturesWithoutReadTextAreCountedAsWaiting() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let other = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_100_000))
        try read(f, f.base.imageID, [line(1, "Invoice")])
        let waiting = try await search(f, "zzz").waitingToBeAnalysed
        #expect(waiting == 1)
        try read(f, other, [line(1, "Receipt")])
        let none = try await search(f, "zzz").waitingToBeAnalysed
        #expect(none == 0)
    }
}
