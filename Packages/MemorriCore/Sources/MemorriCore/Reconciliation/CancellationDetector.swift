import Foundation
import GRDB
import os

/// What the analysis job asks of the detector, so the job is tested with a fake.
public protocol CancellationRecording: Sendable {
    @discardableResult func record(imageID: String, coverage: [CoverageDraft]) throws -> [String]
    func clearContradicted(imageID: String) throws
}

/// Spots meetings that later calendar captures no longer show (spec 010, ADR 0027). It only records evidence (coverage and absences); the review
/// reason `Possibly cancelled` is computed by `ReviewRules` from it, and nothing is ever dismissed, deleted or unsynced from here.
public struct CancellationDetector: CancellationRecording {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "cancellation")

    let database: StorageDatabase
    let now: @Sendable () -> Date

    public init(database: StorageDatabase, now: @escaping @Sendable () -> Date = { Date() }) { self.database = database; self.now = now }

    /// For the first analysis of a capture, after it was reconciled: stores what its calendar views covered and writes an absence for each active,
    /// timed appointment of the capture's context that lies in a covered stretch, was seen before in a captured calendar view, and is not shown here.
    /// A capture with no context stores nothing. Returns the items that are possibly cancelled now and were not before.
    @discardableResult
    public func record(imageID: String, coverage: [CoverageDraft]) throws -> [String] {
        guard !coverage.isEmpty else { return [] }
        let date = now()
        return try database.pool.write { db in
            guard let context = try String?.fetchOne(db, sql: "SELECT context_id FROM image_context WHERE image_id = ?", arguments: [imageID]) ?? nil,
                  let capture = try Row.fetchOne(db, sql: """
                      SELECT e.id AS event_id, e.captured_at FROM capture_images i JOIN capture_events e ON e.id = i.event_id WHERE i.id = ?
                      """, arguments: [imageID]) else { return [] }
            let eventID: String = capture["event_id"], capturedAt: Date = capture["captured_at"]

            for draft in coverage {
                let spans = draft.spans.map { ["from": $0.start.timeIntervalSince1970, "to": $0.end.timeIntervalSince1970] }
                let json = (try? JSONEncoder().encode(spans)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                try db.execute(sql: "INSERT OR REPLACE INTO calendar_coverage (image_id, window_key, kind, spans_json, created_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [imageID, draft.windowKey, draft.kind.rawValue, json, date])
            }
            let spans = coverage.flatMap(\.spans)

            // Items shown here are not absent: their older absences are over.
            let shown = try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM sightings WHERE image_id = ?", arguments: [imageID])
            for id in shown { try db.execute(sql: "DELETE FROM cancel_absences WHERE item_id = ? AND captured_at < ?", arguments: [id, capturedAt]) }

            let candidates = try Row.fetchAll(db, sql: """
                SELECT i.id, i.start_at, i.review_reasons_json FROM items i
                WHERE i.status = 'active' AND i.family = 'event' AND i.all_day = 0 AND i.start_at IS NOT NULL AND i.context_id = ?
                  AND NOT EXISTS (SELECT 1 FROM sightings s WHERE s.item_id = i.id AND s.image_id = ?)
                  AND EXISTS (SELECT 1 FROM sightings s JOIN calendar_coverage c ON c.image_id = s.image_id
                              WHERE s.item_id = i.id AND s.captured_at < ?)
                """, arguments: [context, imageID, capturedAt])
            var touched: [String] = []
            for row in candidates {
                let start: Date = row["start_at"]
                guard spans.contains(where: { $0.start <= start && start <= $0.end }) else { continue }
                let id: String = row["id"]
                try db.execute(sql: "INSERT OR REPLACE INTO cancel_absences (item_id, image_id, event_id, captured_at) VALUES (?, ?, ?, ?)",
                               arguments: [id, imageID, eventID, capturedAt])
                touched.append(id)
            }
            return try Self.refresh(db, touched + shown, at: date)
        }
    }

    /// After a capture was read again (a reanalysis, the library re-read): absences its new sightings contradict are dropped. It never adds one, so
    /// reading old captures again cannot raise a suspicion (FR-008).
    public func clearContradicted(imageID: String) throws {
        let date = now()
        try database.pool.write { db in
            let contradicted = try String.fetchAll(db, sql: """
                SELECT a.item_id FROM cancel_absences a WHERE a.image_id = ?
                  AND EXISTS (SELECT 1 FROM sightings s WHERE s.item_id = a.item_id AND s.image_id = a.image_id)
                """, arguments: [imageID])
            guard !contradicted.isEmpty else { return }
            for id in contradicted { try db.execute(sql: "DELETE FROM cancel_absences WHERE item_id = ? AND image_id = ?", arguments: [id, imageID]) }
            _ = try Self.refresh(db, contradicted, at: date)
        }
    }

    /// Recomputes the items and returns those that are possibly cancelled now and were not before.
    private static func refresh(_ db: Database, _ ids: [String], at date: Date) throws -> [String] {
        var newly: [String] = []
        for id in Set(ids).sorted() {
            let before = try Self.flagged(db, id)
            guard try ItemStore.recompute(db, itemID: id, at: date) else { continue }
            if !before, try Self.flagged(db, id) { newly.append(id) }
        }
        if !newly.isEmpty { logger.info("possibly cancelled: \(newly.count)") }
        return newly
    }

    private static func flagged(_ db: Database, _ id: String) throws -> Bool {
        (try String.fetchOne(db, sql: "SELECT review_reasons_json FROM items WHERE id = ?", arguments: [id]) ?? "").contains(ReviewReason.possiblyCancelled.rawValue)
    }
}
