import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// The index is derived: it is built when missing or outdated, and a rebuild gives what the live triggers give (spec 007, FR-012, SC-005).
@Suite struct SearchIndexTests {
    private func line(_ text: String) -> RecognisedLine { RecognisedLine(n: 1, text: text, box: PixelBox(x: 0, y: 0, width: 10, height: 10), confidence: 0.9) }

    private func read(_ f: ReconcileFixture, _ id: String, _ text: String) throws {
        try OCRStore(database: f.database).save(imageID: id, lines: [line(text)], durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func item(_ f: ReconcileFixture, _ id: String, _ title: String, notes: String? = nil) throws {
        try f.database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO items (id, kind, family, status, title, timezone, confidence, notes, first_seen, last_seen, created_at, updated_at)
                VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', 0.9, ?, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                """, arguments: [id, title, notes])
        }
    }

    /// Forgets the index the way a library from before search looks: no rows, no version.
    private func wipe(_ f: ReconcileFixture) throws {
        try f.database.pool.write { db in
            try db.execute(sql: "DELETE FROM search_items"); try db.execute(sql: "DELETE FROM search_captures"); try db.execute(sql: "DELETE FROM search_meta")
        }
    }

    private func version(_ f: ReconcileFixture) throws -> String? {
        try f.read { try String.fetchOne($0, sql: "SELECT value FROM search_meta WHERE key = 'index_version'") }
    }

    private func count(_ f: ReconcileFixture, _ table: String) throws -> Int { try f.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 } }

    /// 230 pictures with text and a few items.
    private func library(pictures: Int = 230) throws -> ReconcileFixture {
        let f = try ReconcileFixture()
        try read(f, f.base.imageID, "Invoice 0")
        for n in 1..<pictures {
            let id = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 60))
            try read(f, id, "Invoice \(n)")
        }
        try item(f, "i1", "Daily standup", notes: "room four"); try item(f, "i2", "Café - Pruebas")
        return f
    }

    @Test func aLibraryWithoutAnIndexVersionIsPreparingAndAnEmptyOneIsReady() throws {
        let empty = try ReconcileFixture(); defer { empty.cleanUp() }
        #expect(try SearchIndex(database: empty.database).state() == .ready)
        let f = try library(pictures: 3); defer { f.cleanUp() }
        try wipe(f)
        #expect(try SearchIndex(database: f.database).state() == .preparing(done: 0, total: 5))          // two items and three pictures
    }

    @Test func prepareRebuildsInBatchesOfOneHundredReportingProgressAndSetsTheVersion() async throws {
        let f = try library(); defer { f.cleanUp() }
        try wipe(f)
        let seen = Seen()
        try await SearchIndex(database: f.database).prepare { seen.add($0) }
        let states = seen.all
        #expect(states.last == .ready)
        let dones = states.compactMap { state -> Int? in if case .preparing(let done, _) = state { done } else { nil } }
        #expect(dones == dones.sorted() && dones.last == 232 && dones.count >= 3)         // items first, then three batches of pictures
        #expect(try version(f) == String(SearchIndex.version))
        #expect(try count(f, "search_items") == 2 && count(f, "search_captures") == 230)
        let hits = try await SearchService(database: f.database).search(SearchQuery(text: "invoice 229"))
        #expect(hits.captures.count == 1)
    }

    @Test func aCurrentIndexIsLeftAlone() async throws {
        let f = try library(pictures: 5); defer { f.cleanUp() }
        try await SearchIndex(database: f.database).prepare { _ in }
        let seen = Seen()
        try await SearchIndex(database: f.database).prepare { seen.add($0) }
        #expect(seen.all.isEmpty)
        #expect(try SearchIndex(database: f.database).state() == .ready)
    }

    @Test func anOutdatedVersionOrAMissingRowRebuilds() async throws {
        let f = try library(pictures: 5); defer { f.cleanUp() }
        let index = SearchIndex(database: f.database)
        try await index.prepare { _ in }
        try await f.database.pool.write { db in try db.execute(sql: "UPDATE search_meta SET value = '0' WHERE key = 'index_version'"); try db.execute(sql: "DELETE FROM search_captures") }
        #expect(try index.state() != .ready)
        try await index.prepare { _ in }
        #expect(try count(f, "search_captures") == 5 && version(f) == String(SearchIndex.version))
        // the version is current but an item's row went missing: the probe notices
        try await f.database.pool.write { db in try db.execute(sql: "DELETE FROM search_items WHERE item_id = 'i1'") }
        let seen = Seen()
        try await index.prepare { seen.add($0) }
        #expect(!seen.all.isEmpty)
        #expect(try count(f, "search_items") == 2)
    }

    @Test func writesDuringTheRebuildAreKept() async throws {
        let f = try library(); defer { f.cleanUp() }
        try wipe(f)
        let fresh = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_900_000))
        let flag = Seen(), database = f.database
        try await SearchIndex(database: database).prepare { state in
            if flag.all.isEmpty {
                try? database.pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                        VALUES ('late', 'appointment', 'event', 'active', 'Late arrival', 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                        """)
                }
                try? OCRStore(database: database).save(imageID: fresh, lines: [RecognisedLine(n: 1, text: "Zebra crossing", box: PixelBox(x: 0, y: 0, width: 10, height: 10), confidence: 0.9)],
                                                      durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_800_000_000))
            }
            flag.add(state)
        }
        let service = SearchService(database: f.database)
        #expect(try await service.search(SearchQuery(text: "arrival")).items.map(\.id) == ["late"])
        #expect(try await service.search(SearchQuery(text: "zebra")).captures.map(\.id) == [fresh])
        #expect(try await service.search(SearchQuery(text: "invoice 100")).captures.count == 1)
    }

    @Test func aFullRebuildEqualsTheIndexTheWritesKept() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Café - Pruebas", notes: "sala grande", place: "Madrid", people: ["Ana Pérez"], aliases: ["Pruebas Café"])
        try f.addItem("b", title: "Dentist", status: "dismissed")
        try f.addItem("c", title: "Merged away", status: "merged")
        try f.addItem("d", title: "Pay rent", kind: "task", due: SearchFixture.date(3))
        let live = try snapshot(f.database)
        try SearchIndex(database: f.database).rebuild()
        let rebuilt = try snapshot(f.database)
        #expect(live == rebuilt && live.count == 3)
        let queries = ["cafe", "pru", "sala", "madrid", "perez", "dentist", "pay", "merged", "pruebas cafe", "\"pruebas cafe\"", "rent -pay", "x"]
        for text in queries { _ = try await f.service.search(SearchQuery(text: text, includeDismissed: true)) }
    }

    private func snapshot(_ db: StorageDatabase) throws -> [String] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT item_id, title, aliases, notes, place, people FROM search_items ORDER BY item_id").map { row in
                row.databaseValues.map { "\($0)" }.joined(separator: "|")
            } + Row.fetchAll(db, sql: "SELECT image_id, body FROM search_captures ORDER BY image_id").map { row in row.databaseValues.map { "\($0)" }.joined(separator: "|") }
        }
    }

    /// A database as the app before search left it (migrated to v8, an item in it).
    private func makeV8Library(_ paths: AppPaths) throws {
        let pool = try DatabasePool(path: paths.database.path)
        try Migrations.make().migrate(pool, upTo: "v8")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                VALUES ('i1', 'appointment', 'event', 'active', 'Daily standup', 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                """)
        }
        try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        try pool.close()
    }

    @Test func aLibraryFromBeforeSearchIsSearchableOnceItIsPrepared() async throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri")); try paths.prepare()
        try makeV8Library(paths)
        guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { Issue.record("not opened"); return }
        let service = SearchService(database: db)
        #expect(try await service.search(SearchQuery(text: "standup")).items.isEmpty)           // the triggers only see what changes
        #expect(try SearchIndex(database: db).state() == .preparing(done: 0, total: 1))
        try await SearchIndex(database: db).prepare { _ in }
        #expect(try await service.search(SearchQuery(text: "standup")).items.map(\.id) == ["i1"])
        #expect(try SearchIndex(database: db).state() == .ready)
    }
}

/// Collects what `prepare` reports, from whichever thread it runs on.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SearchState] = []
    func add(_ state: SearchState) { lock.lock(); states.append(state); lock.unlock() }
    var all: [SearchState] { lock.lock(); defer { lock.unlock() }; return states }
}
