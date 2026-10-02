import Foundation
import GRDB
@testable import MemorriCore

/// A database with items written straight to the tables (the search triggers do the rest), for the search tests that do not need the reconciler.
final class SearchFixture {
    let temp = TempDirectory()
    let database: StorageDatabase
    var service: SearchService { SearchService(database: database) }

    init() throws {
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let db) = try StorageDatabase.open(paths: paths) else { throw SearchFixtureError.notOpened }
        database = db
    }

    func cleanUp() { temp.cleanUp() }

    static func date(_ day: Int, month: Int = 10, hour: Int = 10) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @discardableResult
    func addItem(_ id: String, title: String, kind: String = "appointment", notes: String? = nil, place: String? = nil, people: [String] = [],
                 aliases: [String] = [], status: String = "active", context: String? = nil, start: Date? = nil, due: Date? = nil,
                 needsReview: Bool = false, lastSeen: Date = SearchFixture.date(1)) throws -> String {
        let family = kind == "appointment" ? "event" : "todo"
        let peopleJSON = String(decoding: try JSONEncoder().encode(people), as: UTF8.self)
        try database.pool.write { db in
            if let context {
                try db.execute(sql: "INSERT OR IGNORE INTO contexts (id, name, timezone, created_at, updated_at) VALUES (?, ?, 'UTC', datetime('now'), datetime('now'))",
                               arguments: [context, context])
            }
            try db.execute(sql: """
                INSERT INTO items (id, kind, family, status, context_id, title, start_at, due_at, timezone, people_json, place, notes, confidence,
                                   needs_review, first_seen, last_seen, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'UTC', ?, ?, ?, 0.9, ?, ?, ?, datetime('now'), datetime('now'))
                """, arguments: [id, kind, family, status, context, title, start, due, peopleJSON, place, notes, needsReview ? 1 : 0, lastSeen, lastSeen])
            for alias in aliases {
                try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES (?, ?, ?)", arguments: [id, alias.lowercased(), alias])
            }
        }
        return id
    }
}

enum SearchFixtureError: Error { case notOpened }
