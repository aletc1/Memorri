import Foundation
import GRDB
import os

/// Runs a search over the index (spec 007, ADR 0023). Items come first, then captures; typed text never reaches the index unquoted.
public struct SearchService: Sendable {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "search")

    let database: StorageDatabase

    public init(database: StorageDatabase) { self.database = database }

    public func search(_ query: SearchQuery, itemLimit: Int = 20, captureLimit: Int = 20, itemOffset: Int = 0, captureOffset: Int = 0) async throws -> SearchResults {
        guard let expression = query.matchExpression else { return .empty }
        let started = ContinuousClock.now
        let terms = query.terms
        let results = try await database.pool.read { db -> SearchResults in
            var items: [ItemHit] = [], moreItems = false
            if Self.includesItems(query) {
                let found = try Self.itemHits(db, expression: expression, terms: terms, query: query, limit: itemLimit + 1, offset: itemOffset)
                moreItems = found.count > itemLimit
                items = Array(found.prefix(itemLimit))
            }
            let waiting = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM capture_images i WHERE i.missing = 0 AND NOT EXISTS (SELECT 1 FROM ocr_reads r WHERE r.image_id = i.id)
                """) ?? 0
            return SearchResults(items: items, captures: [], moreItems: moreItems, moreCaptures: false, waitingToBeAnalysed: waiting)
        }
        let elapsed = started.duration(to: .now).components
        Self.logger.info("search items=\(results.items.count) captures=\(results.captures.count) ms=\(Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))")
        return results
    }

    /// The ids of the items that match, best first, for the Items window's search field.
    public func itemIDs(matching query: SearchQuery) async throws -> [String] {
        guard let expression = query.matchExpression, Self.includesItems(query) else { return [] }
        let terms = query.terms
        return try await database.pool.read { db in
            try Self.itemHits(db, expression: expression, terms: terms, query: query, limit: 1000, offset: 0).map(\.id)
        }
    }

    /// Fires after every change to what search reads (items, aliases, the text of captures), so an open panel can ask again.
    public func changes() -> AsyncStream<Void> {
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM items) + (SELECT COUNT(*) FROM item_aliases) + (SELECT COUNT(*) FROM ocr_reads)") ?? 0
        }
        let pool = database.pool
        return AsyncStream { continuation in
            let task = Task {
                do { for try await _ in observation.values(in: pool) { continuation.yield(()) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Items

    private static func includesItems(_ query: SearchQuery) -> Bool { query.kinds.isEmpty || !query.kinds.isDisjoint(with: [.appointments, .tasks, .reminders]) }

    /// The SQL conditions and arguments for the item filters (kind, context, date, dismissed). The item table is `items`.
    private static func itemFilter(_ query: SearchQuery) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var conditions: [String] = [], arguments: [any DatabaseValueConvertible] = []
        conditions.append(query.includeDismissed ? "items.status IN ('active', 'dismissed')" : "items.status = 'active'")
        var kinds: [String] = []
        for kind in query.kinds {
            switch kind {
            case .appointments: kinds += ["appointment"]
            case .tasks: kinds += ["task", "deadline"]
            case .reminders: kinds += ["reminder"]
            case .captures: break
            }
        }
        if !kinds.isEmpty {
            conditions.append("items.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            arguments += kinds
        }
        switch query.context {
        case .any: break
        case .none: conditions.append("items.context_id IS NULL")
        case .one(let id): conditions.append("items.context_id = ?"); arguments.append(id)
        }
        if let dates = query.dates {
            conditions.append("(CASE WHEN items.family = 'event' THEN items.start_at ELSE COALESCE(items.due_at, items.start_at) END) BETWEEN ? AND ?")
            arguments += [dates.lowerBound, dates.upperBound]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    private static func itemHits(_ db: Database, expression: String, terms: SearchQuery.Terms, query: SearchQuery, limit: Int, offset: Int) throws -> [ItemHit] {
        let filter = itemFilter(query)
        let rows = try Row.fetchAll(db, sql: """
            SELECT items.id, items.kind, items.family, items.title, items.status, items.needs_review, items.context_id, items.start_at, items.due_at,
                   search_items.aliases, search_items.notes, search_items.place, search_items.people
            FROM search_items JOIN items ON items.id = search_items.item_id
            WHERE search_items MATCH ? AND \(filter.sql)
            ORDER BY bm25(search_items, 0, 10, 6, 2, 2, 2), items.last_seen DESC, items.id
            LIMIT ? OFFSET ?
            """, arguments: StatementArguments([expression]) + StatementArguments(filter.arguments) + [limit, offset])
        return rows.compactMap { row -> ItemHit? in
            guard let kind = FindingKind(rawValue: row["kind"]), let status = ItemStatus(rawValue: row["status"]) else { return nil }
            let title: String = row["title"]
            let marked = MarkedText(title, terms: terms)
            var field = SearchField.title
            var snippet: MarkedText?
            if marked.marks.isEmpty {
                let candidates: [(SearchField, String)] = [(.alias, row["aliases"]), (.notes, row["notes"]), (.place, row["place"]), (.people, row["people"])]
                for (candidate, text) in candidates where !text.isEmpty && !SearchText.marks(of: terms, in: text).isEmpty {
                    field = candidate
                    snippet = Self.excerpt(text, terms: terms)
                    break
                }
            }
            let date: Date? = (row["family"] as String) == "event" ? row["start_at"] : ((row["due_at"] as Date?) ?? row["start_at"])
            return ItemHit(id: row["id"], kind: kind, title: marked, date: date, contextID: row["context_id"], status: status,
                           needsReview: (row["needs_review"] as Int) != 0, matchedIn: field, snippet: snippet)
        }
    }

    /// A short stretch of `text` around the first matching word, with the matches marked.
    static func excerpt(_ text: String, terms: SearchQuery.Terms, length: Int = 140) -> MarkedText {
        guard text.count > length, let first = SearchText.marks(of: terms, in: text).first else { return MarkedText(text, terms: terms) }
        let before = text.distance(from: text.startIndex, to: first.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, before - length / 3))
        let end = text.index(start, offsetBy: min(length, text.distance(from: start, to: text.endIndex)))
        return MarkedText(String(text[start..<end]), terms: terms)
    }
}
