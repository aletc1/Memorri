import Foundation
import GRDB

public struct AppFacts: Sendable, Equatable {
    public let version: String
    public let build: String
    public let system: String

    public init(version: String, build: String, system: String) { self.version = version; self.build = build; self.system = system }
}

public struct PermissionState: Sendable, Equatable {
    public let name: String
    public let state: String

    public init(name: String, state: String) { self.name = name; self.state = state }
}

/// Everything a report says, as figures and short states: no item text, no OCR text, no model output, no window titles (spec 010 FR-025).
public struct DiagnosticsInputs: Sendable, Equatable {
    public struct QueueRow: Sendable, Equatable { public let kind: String; public let state: String; public let count: Int }
    public struct Failure: Sendable, Equatable { public let kind: String; public let reason: String; public let count: Int }
    public struct SyncLine: Sendable, Equatable { public let finishedAt: Date; public let preview: Bool; public let summary: String; public let notes: [String] }

    public let app: AppFacts
    public let permissions: [PermissionState]
    public let queue: [QueueRow]
    public let failures: [Failure]
    public let syncRuns: [SyncLine]
    public let items: Int
    public let inbox: Int
    public let captures: Int
    public let pictureBytes: Int64
    public let databaseBytes: Int64
    public let evidenceBytes: Int64
    public let safetyCopyBytes: Int64
    public let generatedAt: Date
}

/// Reads the figures from the library; strings from it are only ever compared against, never copied.
public struct DiagnosticsGatherer: Sendable {
    let database: StorageDatabase
    let paths: AppPaths

    public init(database: StorageDatabase, paths: AppPaths) { self.database = database; self.paths = paths }

    public func inputs(app: AppFacts, permissions: [PermissionState], now: Date) throws -> DiagnosticsInputs {
        let storage = StorageStats(paths: paths, store: CaptureStore(database: database))
        let summary = try storage.summary()
        return try database.pool.read { db in
            let queue = try Row.fetchAll(db, sql: "SELECT kind, state, COUNT(*) AS n FROM analysis_jobs GROUP BY kind, state ORDER BY kind, state")
                .map { DiagnosticsInputs.QueueRow(kind: $0["kind"], state: $0["state"], count: $0["n"]) }
            let failures = try Row.fetchAll(db, sql: """
                SELECT kind, COALESCE(failure_reason, 'no reason recorded') AS reason, COUNT(*) AS n FROM analysis_jobs WHERE state = 'failed' GROUP BY kind, reason ORDER BY n DESC LIMIT 20
                """).map { DiagnosticsInputs.Failure(kind: $0["kind"], reason: $0["reason"], count: $0["n"]) }
            let runs = try Row.fetchAll(db, sql: "SELECT * FROM sync_runs ORDER BY started_at DESC, rowid DESC LIMIT 10").map { row -> DiagnosticsInputs.SyncLine in
                var run = SyncRunRecord(id: row["id"], startedAt: row["started_at"], finishedAt: row["finished_at"], preview: (row["preview"] as Int) != 0)
                run.created = row["created"]; run.updated = row["updated"]; run.removed = row["removed"]; run.adopted = row["adopted"]; run.skipped = row["skipped"]; run.failed = row["failed"]
                let notes = (row["detail_json"] as String?).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                return DiagnosticsInputs.SyncLine(finishedAt: run.finishedAt, preview: run.preview, summary: SyncWords.summary(run), notes: notes)
            }
            return DiagnosticsInputs(app: app, permissions: permissions, queue: queue, failures: failures, syncRuns: runs,
                                     items: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0,
                                     inbox: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE status = 'active' AND needs_review = 1") ?? 0,
                                     captures: summary.captureCount, pictureBytes: summary.pictureBytes, databaseBytes: summary.databaseBytes,
                                     evidenceBytes: summary.evidenceBytes, safetyCopyBytes: summary.safetyCopyBytes, generatedAt: now)
        }
    }

    /// The strings of the library a report must not contain (lower case): titles, places, people, notes, window titles, context names, aliases.
    public func sensitiveStrings() throws -> Set<String> {
        try database.pool.read { db in
            var strings: Set<String> = []
            func add(_ sql: String) throws { for value in try String.fetchAll(db, sql: sql) { strings.insert(value.lowercased()) } }
            try add("SELECT title FROM items")
            try add("SELECT place FROM items WHERE place IS NOT NULL")
            try add("SELECT notes FROM items WHERE notes IS NOT NULL")
            try add("SELECT title FROM sightings")
            try add("SELECT window_title FROM sightings WHERE window_title IS NOT NULL")
            try add("SELECT title FROM window_readings WHERE title IS NOT NULL")
            try add("SELECT title FROM item_aliases")
            try add("SELECT name FROM contexts")
            // What the newest captures read: a log line must not repeat a line of text from the screen (up to 200 captures, lines of 4 to 160 characters).
            try add("""
                SELECT text FROM ocr_lines WHERE image_id IN (
                    SELECT i.id FROM capture_images i JOIN capture_events e ON e.id = i.event_id ORDER BY e.captured_at DESC LIMIT 200)
                  AND length(text) BETWEEN 4 AND 160
                """)
            for json in try String.fetchAll(db, sql: "SELECT people_json FROM items WHERE people_json != '[]'") {
                for person in (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [] { strings.insert(person.lowercased()) }
            }
            // Pieces of a name count too: a log line may carry only the surname.
            for whole in strings where whole.count > Self.shortestPiece {
                for piece in whole.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where piece.count >= LogSanitiser.shortestSecret + 2 { strings.insert(String(piece)) }
            }
            return strings
        }
    }

    private static let shortestPiece = 6
}

/// A diagnostic report as plain text and as JSON.
public struct DiagnosticsReport: Sendable, Equatable {
    public let text: String
    public let json: String

    public static func build(_ inputs: DiagnosticsInputs, log: [LogLine], sensitive: Set<String>) -> DiagnosticsReport {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let formatter = ISO8601DateFormatter()
        let failures = inputs.failures.map { ($0.kind, LogSanitiser.sanitiseReason($0.reason, sensitive: sensitive), $0.count) }
        let notes = inputs.syncRuns.map { run in (run, run.notes.map { LogSanitiser.sanitiseReason($0, sensitive: sensitive) }) }
        let kept = log.filter { LogSanitiser.keep($0, sensitive: sensitive) }

        var lines: [String] = []
        lines.append("Memorri diagnostics, \(formatter.string(from: inputs.generatedAt))")
        lines.append("Version \(inputs.app.version) (\(inputs.app.build)) on \(inputs.app.system)")
        lines.append(""); lines.append("Permissions")
        for permission in inputs.permissions { lines.append("  \(permission.name): \(permission.state)") }
        lines.append(""); lines.append("Library")
        lines.append("  Items: \(inputs.items) (\(inputs.inbox) in the Inbox)")
        lines.append("  Captures: \(inputs.captures)")
        lines.append("  Pictures \(size(inputs.pictureBytes)), database \(size(inputs.databaseBytes)), evidence \(size(inputs.evidenceBytes)), safety copies \(size(inputs.safetyCopyBytes))")
        lines.append(""); lines.append("Queue")
        if inputs.queue.isEmpty { lines.append("  empty") }
        for row in inputs.queue { lines.append("  \(row.kind) \(row.state): \(row.count)") }
        if !failures.isEmpty {
            lines.append(""); lines.append("Failures")
            for failure in failures { lines.append("  \(failure.0) ×\(failure.2): \(failure.1)") }
        }
        lines.append(""); lines.append("Calendar sync (last runs)")
        if notes.isEmpty { lines.append("  none") }
        for (run, runNotes) in notes {
            lines.append("  \(formatter.string(from: run.finishedAt)) \(run.summary)")
            for note in runNotes.prefix(3) { lines.append("    \(note)") }
        }
        lines.append(""); lines.append("Recent log (\(kept.count) of \(log.count) lines; lines that might hold content are left out)")
        for line in kept { lines.append("  \(formatter.string(from: line.date)) [\(line.category)] \(line.text)") }

        let object: [String: Any] = [
            "generatedAt": formatter.string(from: inputs.generatedAt),
            "app": ["version": inputs.app.version, "build": inputs.app.build, "system": inputs.app.system],
            "permissions": Dictionary(uniqueKeysWithValues: inputs.permissions.map { ($0.name, $0.state) }),
            "library": ["items": inputs.items, "inbox": inputs.inbox, "captures": inputs.captures, "pictureBytes": inputs.pictureBytes, "databaseBytes": inputs.databaseBytes,
                        "evidenceBytes": inputs.evidenceBytes, "safetyCopyBytes": inputs.safetyCopyBytes],
            "queue": inputs.queue.map { ["kind": $0.kind, "state": $0.state, "count": $0.count] as [String: Any] },
            "failures": failures.map { ["kind": $0.0, "reason": $0.1, "count": $0.2] as [String: Any] },
            "sync": notes.map { ["at": formatter.string(from: $0.0.finishedAt), "summary": $0.0.summary, "notes": $0.1] as [String: Any] },
            "log": kept.map { ["at": formatter.string(from: $0.date), "category": $0.category, "text": $0.text] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return DiagnosticsReport(text: lines.joined(separator: "\n") + "\n", json: String(decoding: data, as: UTF8.self))
    }
}
