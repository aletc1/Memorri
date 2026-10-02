import Foundation
import GRDB

/// When and from which display a capture was taken, for the comparison's headings.
public struct TrialCaptureInfo: Sendable, Equatable {
    public let capturedAt: Date
    public let displayName: String?
}

/// One apply of a trial, as the audit trail lists it.
public struct TrialHistoryEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let undone: Bool
    public let model: String
    public let promptVersion: String
    public let applied: Int
    public let items: Int
    /// When the trial was started and how many captures it had read when it was applied; they stay after the trial is deleted.
    public let trialStarted: Date?
    public let captures: Int
}

extension TrialStore {
    public func captureInfo(imageIDs: [String]) throws -> [String: TrialCaptureInfo] {
        try database.pool.read { db in
            var out: [String: TrialCaptureInfo] = [:]
            for id in imageIDs {
                if let row = try Row.fetchOne(db, sql: """
                    SELECT e.captured_at, i.display_name FROM capture_images i JOIN capture_events e ON e.id = i.event_id WHERE i.id = ?
                    """, arguments: [id]) {
                    out[id] = TrialCaptureInfo(capturedAt: row["captured_at"], displayName: row["display_name"])
                }
            }
            return out
        }
    }

    /// The applies of trials, newest first (the audit trail, spec 008 FR-011). Survives deleting the trial.
    public func history() throws -> [TrialHistoryEntry] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM reconcile_ops WHERE kind = 'apply_trial' ORDER BY created_at DESC, rowid DESC").compactMap { row -> TrialHistoryEntry? in
                guard let op = try OperationLog.fetch(db, id: row["id"]) else { return nil }
                var captures = 0
                if case .int(let n)? = op.detail["captures"] { captures = n }
                return TrialHistoryEntry(id: op.id, createdAt: op.createdAt, undone: op.undoneBy != nil, model: op.detail["model"]?.asString ?? "?",
                                         promptVersion: op.detail["promptVersion"]?.asString ?? "?",
                                         applied: op.detail["differences"]?.arrayValue?.count ?? 0, items: op.itemIDs.count,
                                         trialStarted: op.detail["trialStarted"]?.asString.flatMap { ISO8601DateFormatter().date(from: $0) },
                                         captures: captures)
            }
        }
    }
}

/// The words of the Reprocess section, kept out of the views so they can be tested (spec 008).
public enum TrialWords {
    public static func kind(_ d: TrialDifference) -> String {
        if d.state == .applied { return "Applied" }
        switch d.kind {
        case .new: return "New"
        case .changed: return "Changed"
        case .unchanged: return "Unchanged"
        case .notFound: return "Not found in this trial"
        }
    }

    public static func protection(_ p: ProtectionReason) -> String {
        switch p {
        case .locked(let fields): "You set \(fields.map(\.rawValue).joined(separator: ", "))"
        case .approved: "You approved this item"
        case .dismissed: "You dismissed this item"
        }
    }

    /// `end: Wed 14 Oct 07:30 → Wed 14 Oct 08:00`.
    public static func change(_ c: FieldChange) -> String {
        "\(c.field.rawValue): \(c.current) → \(c.proposed)" + (lookAlike(c).map { " (\($0))" } ?? "")
    }

    /// When two texts of the same length differ in a few letters that may look alike on screen (an `I` and an `l`, a `0` and an `O`),
    /// says which: `letter 19: “l” → “I”`. Nil when the texts differ in more than that, or when they are not texts.
    public static func lookAlike(_ c: FieldChange) -> String? {
        guard [.title, .place, .notes].contains(c.field) else { return nil }
        let a = Array(c.current), b = Array(c.proposed)
        guard a.count == b.count else { return nil }
        let differing = a.indices.filter { a[$0] != b[$0] }
        guard !differing.isEmpty, differing.count <= 3 else { return nil }
        return differing.map { "letter \($0 + 1): “\(a[$0])” → “\(b[$0])”" }.joined(separator: ", ")
    }

    public static func progress(_ trial: TrialRecord) -> String {
        let c = trial.counts
        var parts = ["\(c.read) of \(c.total) read"]
        if c.skipped > 0 { parts.append("\(c.skipped) skipped") }
        if c.failed > 0 { parts.append("\(c.failed) failed") }
        return parts.joined(separator: ", ")
    }

    public static func state(_ trial: TrialRecord) -> String {
        switch trial.state {
        case .running: "Reading"
        case .finished: trial.counts.failed > 0 ? "Finished with failures" : "Finished"
        case .cancelled: "Cancelled"
        }
    }

    public static func totals(_ t: TrialTotals) -> String {
        var parts = ["\(t.new) new", "\(t.changed) changed", "\(t.notFound) not found", "\(t.unchanged) unchanged"]
        if t.protected > 0 { parts.append("\(t.protected) protected") }
        if t.review > 0 { parts.append("\(t.review) would need review") }
        if t.applied > 0 { parts.append("\(t.applied) applied") }
        return parts.joined(separator: " · ")
    }

    public static func outOfDate(_ count: Int) -> String {
        count == 0 ? "Everything was read with the current model and prompt."
            : "\(count) \(count == 1 ? "capture was" : "captures were") read with another model or prompt."
    }
}
