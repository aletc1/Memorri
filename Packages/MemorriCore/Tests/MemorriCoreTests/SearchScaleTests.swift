import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Months of use: search must answer as the user types among thousands of items and hundreds of captures (spec 007, SC-001, SC-005, SC-006).
@Suite struct SearchScaleTests {
    private static let vocabulary: [String] = (0..<3000).map { "palabra\($0)" } + ["budget", "forecast", "invoice", "meeting", "review", "planning", "friday", "customer"]

    private func words(_ n: Int, seed: Int) -> String {
        var generator = SeededGenerator(seed: UInt64(seed))
        return (0..<n).map { _ in Self.vocabulary.randomElement(using: &generator)! }.joined(separator: " ")
    }

    private func build(_ f: ReconcileFixture) throws {
        try f.write { db in
            for n in 0..<5000 {
                try db.execute(sql: """
                    INSERT INTO items (id, kind, family, status, title, timezone, people_json, place, notes, confidence, first_seen, last_seen, created_at, updated_at)
                    VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', ?, ?, ?, 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                    """, arguments: ["item\(n)", "Review number \(n) \(self.words(2, seed: n))", "[\"Persona\(n % 50)\"]", "Sala \(n % 20)", self.words(8, seed: n + 10_000)])
                try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES (?, ?, ?)", arguments: ["item\(n)", "alias\(n)", "Alias \(n) \(self.words(2, seed: n + 20_000))"])
            }
        }
        var ids = [f.base.imageID]
        for n in 1..<200 { ids.append(try f.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 600))) }
        let store = OCRStore(database: f.database)
        for (index, id) in ids.enumerated() {
            let lines = (1...1000).map { n in
                RecognisedLine(n: n, text: words(6, seed: index * 1000 + n) + (index % 7 == 0 && n == 500 ? " zebracrossing" : ""),
                               box: PixelBox(x: 0, y: n * 12, width: 400, height: 10), confidence: 0.9)
            }
            try store.save(imageID: id, lines: lines, durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    private func best(_ runs: Int = 3, _ body: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        for _ in 0..<runs {
            let started = clock.now
            try await body()
            best = min(best, started.duration(to: clock.now))
        }
        return best
    }

    @Test func resultsStayUnderTwoHundredMillisecondsAmongFiveThousandItemsAndTwoHundredThousandLines() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try build(f)
        #expect(try f.count("items") == 5000 && f.count("search_items") == 5000 && f.count("search_captures") == 200)
        let service = SearchService(database: f.database)
        var typical: SearchResults?
        let fast = try await best { typical = try await service.search(SearchQuery(text: "review number 42")) }
        #expect(typical?.items.first?.title.text.hasPrefix("Review number 42") == true)
        #expect(fast < .milliseconds(200), "typical query took \(fast)")
        var common: SearchResults?
        let common200 = try await best { common = try await service.search(SearchQuery(text: "budget forecast")) }
        #expect(common?.captures.count == 20 && common?.moreCaptures == true)
        #expect(common200 < .milliseconds(200), "common words took \(common200)")
        var rare: SearchResults?
        let rareTime = try await best { rare = try await service.search(SearchQuery(text: "zebracrossing")) }
        #expect(rare?.captures.count == 20 && rare?.moreCaptures == true)         // 29 pictures hold it (0, 7, 14, ... 196): one page and more
        #expect(rareTime < .milliseconds(200), "rare word took \(rareTime)")
        let first = try await best(1) { _ = try await service.search(SearchQuery(text: "meeting", kinds: [.appointments])) }
        #expect(first < .milliseconds(300), "first results took \(first)")
        print("search-scale typical=\(fast) common=\(common200) rare=\(rareTime) first=\(first)")
    }

    @Test func aFullRebuildGivesTheIndexTheWritesKept() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try build(f)
        func snapshot() throws -> (items: [String], captures: [String]) {
            try f.read { db in
                (try Row.fetchAll(db, sql: "SELECT item_id || '|' || title || '|' || aliases || '|' || notes || '|' || place || '|' || people AS s FROM search_items ORDER BY item_id").map { $0["s"] as String },
                 try Row.fetchAll(db, sql: "SELECT image_id || '|' || body AS s FROM search_captures ORDER BY image_id").map { $0["s"] as String })
            }
        }
        let live = try snapshot()
        try SearchIndex(database: f.database).rebuild()
        let rebuilt = try snapshot()
        #expect(live.items == rebuilt.items && live.captures == rebuilt.captures)
    }

    @Test func writingACapturesDocumentCostsFarLessThanAnAnalysis() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let lines = (1...1000).map { RecognisedLine(n: $0, text: words(6, seed: $0), box: PixelBox(x: 0, y: $0 * 12, width: 400, height: 10), confidence: 0.9) }
        try OCRStore(database: f.database).save(imageID: f.base.imageID, lines: lines, durationMs: 1, recogniser: "test", at: Date())
        let clock = ContinuousClock()
        var best = Duration.seconds(1000)
        for _ in 0..<3 {
            let started = clock.now
            try f.write { try SearchIndex.writeCapture($0, imageID: f.base.imageID, lines: lines) }
            best = min(best, started.duration(to: clock.now))
        }
        // An analysis takes seconds (8 s a case in the eval); 5% of even one second is 50 ms.
        #expect(best < .milliseconds(50), "the document took \(best)")
    }
}

/// A repeatable stream of numbers, so the test data does not change between runs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
