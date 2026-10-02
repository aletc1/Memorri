import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Kind, context and date filters (spec 007, US3). They narrow items and captures with the same rules as the Items window.
@Suite struct SearchFilterTests {
    private func seed(_ f: SearchFixture) throws {
        try f.addItem("meeting", title: "Review meeting", kind: "appointment", context: "ctxA", start: SearchFixture.date(5))
        try f.addItem("task", title: "Review contract", kind: "task", context: "ctxA", due: SearchFixture.date(10))
        try f.addItem("deadline", title: "Review deadline", kind: "deadline", context: "ctxB", due: SearchFixture.date(20))
        try f.addItem("reminder", title: "Review reminder", kind: "reminder", context: nil, due: SearchFixture.date(10, month: 11))
        try f.addItem("undated", title: "Review notes", kind: "task", context: nil)
        try f.addItem("old", title: "Review archive", kind: "appointment", status: "dismissed", context: "ctxA", start: SearchFixture.date(2))
    }

    private func ids(_ f: SearchFixture, _ query: SearchQuery) async throws -> Set<String> {
        Set(try await f.service.search(query).items.map(\.id))
    }

    @Test func kindsNarrowItemsAndTasksIncludeDeadlines() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try seed(f)
        #expect(try await ids(f, SearchQuery(text: "review")) == ["meeting", "task", "deadline", "reminder", "undated"])
        #expect(try await ids(f, SearchQuery(text: "review", kinds: [.appointments])) == ["meeting"])
        #expect(try await ids(f, SearchQuery(text: "review", kinds: [.tasks])) == ["task", "deadline", "undated"])
        #expect(try await ids(f, SearchQuery(text: "review", kinds: [.reminders])) == ["reminder"])
        #expect(try await ids(f, SearchQuery(text: "review", kinds: [.appointments, .reminders])) == ["meeting", "reminder"])
        #expect(try await ids(f, SearchQuery(text: "review", kinds: [.captures])) == [])
    }

    @Test func contextsNarrowAndNoContextMeansNone() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try seed(f)
        #expect(try await ids(f, SearchQuery(text: "review", context: .one("ctxA"))) == ["meeting", "task"])
        #expect(try await ids(f, SearchQuery(text: "review", context: .one("ctxB"))) == ["deadline"])
        #expect(try await ids(f, SearchQuery(text: "review", context: .none)) == ["reminder", "undated"])
        #expect(try await ids(f, SearchQuery(text: "review", context: .one("nobody"))) == [])
    }

    @Test func datesUseStartForEventsAndDueForToDosAndKeepBothEnds() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try seed(f)
        let october = SearchFixture.date(1, hour: 0)...SearchFixture.date(31, hour: 23)
        #expect(try await ids(f, SearchQuery(text: "review", dates: october)) == ["meeting", "task", "deadline"])      // undated is out of a range
        #expect(try await ids(f, SearchQuery(text: "review", dates: SearchFixture.date(10)...SearchFixture.date(20))) == ["task", "deadline"])   // both ends inclusive
        #expect(try await ids(f, SearchQuery(text: "review", dates: SearchFixture.date(1, month: 11, hour: 0)...SearchFixture.date(30, month: 11))) == ["reminder"])
        #expect(try await ids(f, SearchQuery(text: "review", dates: SearchFixture.date(1, month: 12)...SearchFixture.date(2, month: 12))) == [])
    }

    @Test func dismissedItemsNeedTheChoice() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try seed(f)
        #expect(try await ids(f, SearchQuery(text: "review", includeDismissed: true)).contains("old"))
        #expect(try await ids(f, SearchQuery(text: "review")).contains("old") == false)
    }

    @Test func filtersCombine() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try seed(f)
        let q = SearchQuery(text: "review", kinds: [.appointments, .tasks], context: .one("ctxA"), dates: SearchFixture.date(1, hour: 0)...SearchFixture.date(8), includeDismissed: true)
        #expect(try await ids(f, q) == ["meeting", "old"])
        let items = try await f.service.itemIDs(matching: q)
        #expect(Set(items) == ["meeting", "old"])
        #expect(try await f.service.itemIDs(matching: SearchQuery(text: "review", kinds: [.captures])) == [])
    }

    // MARK: captures

    private func read(_ f: ReconcileFixture, _ id: String, _ text: String) throws {
        try OCRStore(database: f.database).save(imageID: id, lines: [RecognisedLine(n: 1, text: text, box: PixelBox(x: 0, y: 0, width: 10, height: 10), confidence: 0.9)],
                                                durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func assign(_ f: ReconcileFixture, _ image: String, context: String) throws {
        try f.addContext(context, context)
        try f.database.pool.write { db in
            try db.execute(sql: "INSERT INTO image_context (image_id, context_id, source, score, matched_json, decided_at) VALUES (?, ?, 'auto', 1, '[]', datetime('now'))",
                           arguments: [image, context])
        }
    }

    @Test func capturesFilterByKindContextAndTime() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let first = f.base.imageID
        let second = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + 40 * 86_400))
        for id in [first, second] { try read(f, id, "Invoice 2291") }
        try assign(f, first, context: "ctxA")
        let service = SearchService(database: f.database)
        func captureIDs(_ q: SearchQuery) async throws -> Set<String> { Set(try await service.search(q).captures.map(\.id)) }
        #expect(try await captureIDs(SearchQuery(text: "invoice")) == [first, second])
        #expect(try await captureIDs(SearchQuery(text: "invoice", kinds: [.tasks])) == [])               // other kinds hide captures
        #expect(try await captureIDs(SearchQuery(text: "invoice", kinds: [.captures])) == [first, second])
        #expect(try await captureIDs(SearchQuery(text: "invoice", context: .one("ctxA"))) == [first])
        #expect(try await captureIDs(SearchQuery(text: "invoice", context: .none)) == [second])
        let early = Date(timeIntervalSince1970: 1_800_000_000 - 3600)...Date(timeIntervalSince1970: 1_800_000_000 + 3600)
        #expect(try await captureIDs(SearchQuery(text: "invoice", dates: early)) == [first])
    }
}
