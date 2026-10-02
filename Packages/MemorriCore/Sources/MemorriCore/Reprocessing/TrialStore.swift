import Foundation
import GRDB

public enum TrialState: String, Sendable, Equatable { case running, finished, cancelled }

public enum TrialImageState: String, Sendable, Equatable { case waiting, read, skipped, failed }

public enum TrialError: Error, Equatable {
    /// No stored capture has an analysis to compare with.
    case nothingToRead
    case notFound
}

/// How far a trial has got, by capture.
public struct TrialCounts: Sendable, Equatable {
    public var waiting = 0, read = 0, skipped = 0, failed = 0
    public var total: Int { waiting + read + skipped + failed }
    public init(waiting: Int = 0, read: Int = 0, skipped: Int = 0, failed: Int = 0) {
        self.waiting = waiting; self.read = read; self.skipped = skipped; self.failed = failed
    }
}

/// One trial: a model and prompt version read over the stored captures, its results kept apart from the items (spec 008, ADR 0025).
public struct TrialRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let model: String
    public let promptVersion: String
    public let think: String
    public let state: TrialState
    public let createdAt: Date
    public let finishedAt: Date?
    public let counts: TrialCounts
}

/// The proposals of one trial: what it read from each capture, and the trial's own tables. A trial never writes `findings`, `model_runs`,
/// `image_analysis`, items or sightings.
public struct TrialStore: Sendable {
    /// Below new captures (0) and what the user asks for; the same as the library re-read.
    public static let priority = 1
    public static let jobKind = "trial"

    let database: StorageDatabase
    private let paths: AppPaths

    public init(database: StorageDatabase, paths: AppPaths) { self.database = database; self.paths = paths }

    // MARK: Starting and stopping

    /// Creates a trial over every capture that has an analysis: a job for each one whose picture is kept (newest first), the others
    /// recorded as skipped. Returns the trial.
    @discardableResult
    public func create(model: String, promptVersion: String, think: String, now: Date) throws -> TrialRecord {
        let candidates: [(id: String, full: String, model: String, missing: Bool)] = try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT i.id, i.full_path, i.model_path, i.missing FROM capture_images i JOIN capture_events e ON e.id = i.event_id
                WHERE EXISTS (SELECT 1 FROM image_analysis a WHERE a.image_id = i.id)
                ORDER BY e.captured_at DESC, i.display_id ASC, i.id ASC
                """).map { ($0["id"], $0["full_path"], $0["model_path"], ($0["missing"] as Int) != 0) }
        }
        guard !candidates.isEmpty else { throw TrialError.nothingToRead }
        let trialID = UUID().uuidString
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO trials (id, model, prompt_version, think, state, created_at) VALUES (?, ?, ?, ?, 'running', ?)",
                           arguments: [trialID, model, promptVersion, think, now])
            var offset = 0
            for candidate in candidates {
                let kept = !candidate.missing && [candidate.full, candidate.model].allSatisfy {
                    FileManager.default.fileExists(atPath: paths.root.appendingPathComponent($0).path)
                }
                try db.execute(sql: "INSERT INTO trial_images (trial_id, image_id, state, reason) VALUES (?, ?, ?, ?)",
                               arguments: [trialID, candidate.id, kept ? "waiting" : "skipped", kept ? nil : "picture no longer stored"])
                guard kept else { continue }
                // Created together; the queue orders equal times by id, so nudge each one to keep the newest capture first.
                try AnalysisJobRecord(kind: Self.jobKind, imageId: candidate.id, createdAt: now.addingTimeInterval(Double(offset) * 0.001),
                                      priority: Self.priority, trialId: trialID).insert(db)
                offset += 1
            }
            try Self.finishIfDone(db, trialID: trialID, at: now)
        }
        return try trial(id: trialID) ?? { throw TrialError.notFound }()
    }

    /// Stops reading: waiting jobs are removed, the capture being read finishes, results so far stay.
    public func cancel(_ id: String, now: Date) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM analysis_jobs WHERE trial_id = ? AND state = 'waiting'", arguments: [id])
            try db.execute(sql: "UPDATE trials SET state = 'cancelled', finished_at = ? WHERE id = ? AND state = 'running'", arguments: [now, id])
        }
    }

    /// Reads what is left: captures still waiting, and the ones that failed, get a job again.
    public func resume(_ id: String, now: Date) throws {
        try database.pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM trials WHERE id = ?)", arguments: [id]) == true else { throw TrialError.notFound }
            try db.execute(sql: "UPDATE trial_images SET state = 'waiting', reason = NULL WHERE trial_id = ? AND state = 'failed'", arguments: [id])
            let todo = try String.fetchAll(db, sql: """
                SELECT t.image_id FROM trial_images t JOIN capture_images i ON i.id = t.image_id JOIN capture_events e ON e.id = i.event_id
                WHERE t.trial_id = ?1 AND t.state = 'waiting'
                  AND NOT EXISTS (SELECT 1 FROM analysis_jobs j WHERE j.trial_id = ?1 AND j.image_id = t.image_id AND j.state IN ('waiting', 'running'))
                ORDER BY e.captured_at DESC, i.display_id ASC, i.id ASC
                """, arguments: [id])
            for (offset, image) in todo.enumerated() {
                try AnalysisJobRecord(kind: Self.jobKind, imageId: image, createdAt: now.addingTimeInterval(Double(offset) * 0.001),
                                      priority: Self.priority, trialId: id).insert(db)
            }
            try db.execute(sql: "UPDATE trials SET state = 'running', finished_at = NULL WHERE id = ?", arguments: [id])
            try Self.finishIfDone(db, trialID: id, at: now)
        }
    }

    /// Removes a trial with its proposals and jobs; items and the operation log are not touched.
    public func delete(_ id: String) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM analysis_jobs WHERE trial_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM trials WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Reading

    public func trial(id: String) throws -> TrialRecord? { try database.pool.read { try Self.trials($0).first { $0.id == id } } }

    /// Newest first.
    public func all() throws -> [TrialRecord] { try database.pool.read { try Self.trials($0) } }

    /// The list, again after every change to the trial tables.
    public func observe() -> AsyncStream<[TrialRecord]> {
        let observation = ValueObservation.tracking { db in try Self.trials(db) }
        let pool = database.pool
        return AsyncStream { continuation in
            let task = Task {
                do { for try await trials in observation.values(in: pool) { continuation.yield(trials) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func trials(_ db: Database) throws -> [TrialRecord] {
        let counts = Dictionary(grouping: try Row.fetchAll(db, sql: "SELECT trial_id, state, COUNT(*) AS n FROM trial_images GROUP BY trial_id, state"),
                                by: { $0["trial_id"] as String })
        return try Row.fetchAll(db, sql: "SELECT * FROM trials ORDER BY created_at DESC, id").compactMap { row in
            guard let state = TrialState(rawValue: row["state"]) else { return nil }
            var tally = TrialCounts()
            for entry in counts[row["id"]] ?? [] {
                let n: Int = entry["n"]
                switch TrialImageState(rawValue: entry["state"]) {
                case .waiting?: tally.waiting = n
                case .read?: tally.read = n
                case .skipped?: tally.skipped = n
                case .failed?: tally.failed = n
                case nil: break
                }
            }
            return TrialRecord(id: row["id"], model: row["model"], promptVersion: row["prompt_version"], think: row["think"], state: state,
                               createdAt: row["created_at"], finishedAt: row["finished_at"], counts: tally)
        }
    }

    public func state(trialID: String, imageID: String) throws -> TrialImageState? {
        try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM trial_images WHERE trial_id = ? AND image_id = ?", arguments: [trialID, imageID]).flatMap(TrialImageState.init(rawValue:))
        }
    }

    /// The captures a trial read, newest capture first.
    public func readImageIDs(trialID: String) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT t.image_id FROM trial_images t JOIN capture_images i ON i.id = t.image_id JOIN capture_events e ON e.id = i.event_id
                WHERE t.trial_id = ? AND t.state = 'read' ORDER BY e.captured_at DESC, i.display_id ASC, i.id ASC
                """, arguments: [trialID])
        }
    }

    public func findings(trialID: String, imageID: String) throws -> [Finding] {
        try database.pool.read { try Self.findings($0, trialID: trialID, imageID: imageID) }
    }

    static func findings(_ db: Database, trialID: String, imageID: String) throws -> [Finding] {
        try Row.fetchAll(db, sql: "SELECT * FROM trial_findings WHERE trial_id = ? AND image_id = ? ORDER BY start_at, due_at, created_at, rowid",
                         arguments: [trialID, imageID]).compactMap { row in
            guard let kind = FindingKind(rawValue: row["kind"]) else { return nil }
            func decode<T: Decodable>(_ column: String, _ type: T.Type) -> T? { (row[column] as String?).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) } }
            return Finding(id: row["id"], kind: kind, title: row["title"], allDay: (row["all_day"] as Int) != 0, start: row["start_at"], end: row["end_at"],
                           due: row["due_at"], remind: row["remind_at"], timezone: row["timezone"], people: decode("people_json", [String].self) ?? [],
                           place: row["place"], notes: row["notes"], citedLines: decode("cited_lines_json", [Int].self) ?? [], confidence: row["confidence"],
                           provenance: decode("provenance_json", [String: FieldProvenance].self) ?? [:], unresolved: decode("unresolved_json", [String: String].self) ?? [:],
                           tags: decode("tags_json", [CaptureTag].self) ?? [], windowKey: row["window_key"])
        }
    }

    // MARK: Writing proposals (the job)

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Keeps what a trial read from one capture, replacing an earlier read of it, and marks the capture read. A trial that was cancelled or
    /// deleted meanwhile keeps nothing.
    public func saveProposal(trialID: String, imageID: String, result: AnalysisResult, durationMs: Int, at date: Date) throws {
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM trials WHERE id = ?", arguments: [trialID]) == TrialState.running.rawValue else { return }
            try db.execute(sql: "DELETE FROM trial_findings WHERE trial_id = ? AND image_id = ?", arguments: [trialID, imageID])
            for f in result.findings {
                let window = result.windows.first { $0.windowKey == f.windowKey }
                try db.execute(sql: """
                    INSERT INTO trial_findings (id, trial_id, image_id, kind, title, all_day, start_at, end_at, due_at, remind_at, timezone, people_json,
                        place, notes, cited_lines_json, confidence, provenance_json, unresolved_json, tags_json, window_key, window_app, window_title, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, trialID, imageID, f.kind.rawValue, f.title, f.allDay ? 1 : 0, f.start, f.end, f.due, f.remind, f.timezone,
                                     Self.encode(f.people), f.place, f.notes, Self.encode(f.citedLines), f.confidence, Self.encode(f.provenance),
                                     Self.encode(f.unresolved), Self.encode(f.tags), f.windowKey, window?.appName, window?.title, date])
            }
            try db.execute(sql: "UPDATE trial_images SET state = 'read', reason = NULL, finding_count = ?, duration_ms = ? WHERE trial_id = ? AND image_id = ?",
                           arguments: [result.findings.count, durationMs, trialID, imageID])
            try Self.finishIfDone(db, trialID: trialID, at: date)
        }
    }

    /// Marks a capture skipped (its picture is gone) or failed (with why), when the trial is still running.
    public func mark(trialID: String, imageID: String, _ state: TrialImageState, reason: String?, at date: Date) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE trial_images SET state = ?, reason = ? WHERE trial_id = ? AND image_id = ? AND state = 'waiting'",
                           arguments: [state.rawValue, reason, trialID, imageID])
            try Self.finishIfDone(db, trialID: trialID, at: date)
        }
    }

    private static func finishIfDone(_ db: Database, trialID: String, at date: Date) throws {
        let waiting = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trial_images WHERE trial_id = ? AND state = 'waiting'", arguments: [trialID]) ?? 0
        if waiting == 0 {
            try db.execute(sql: "UPDATE trials SET state = 'finished', finished_at = ? WHERE id = ? AND state = 'running'", arguments: [date, trialID])
        }
    }

    // MARK: Out of date

    /// How many captures a trial would read: those with an analysis (the pictures that are gone are counted as skipped).
    public func eligibleCount() throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM image_analysis") ?? 0 }
    }

    /// The window's application and title of a proposal finding, for the sighting it becomes.
    func window(_ db: Database, findingID: String) throws -> (app: String?, title: String?) {
        let row = try Row.fetchOne(db, sql: "SELECT window_app, window_title FROM trial_findings WHERE id = ?", arguments: [findingID])
        return (row?["window_app"], row?["window_title"])
    }

    /// How many analysed captures were last read with another model or with prompts other than the current ones (FR-013).
    public func outOfDateCount(model: String?, currentPromptVersions: Set<String>) throws -> Int {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT model, prompt_version, classify_version FROM image_analysis").filter { row in
                let version: String = row["prompt_version"]
                let classify: String = row["classify_version"]
                return (row["model"] as String) != model || !currentPromptVersions.contains(version) || !currentPromptVersions.contains(classify)
            }.count
        }
    }
}

extension ExtractionPrompts {
    /// Every prompt version the current code can write to `image_analysis`: classification, windows, and the extraction of each screen kind
    /// (read as one picture or window by window), plus `none` for kinds read by code.
    public static var currentVersions: Set<String> {
        var versions: Set<String> = [classifyVersion, windowsVersion]
        for kind in ScreenKind.allCases { versions.insert(version(for: kind)); versions.insert(version(for: kind, windowed: true)) }
        return versions
    }

    /// The label a trial records: `classify-v2, windows-v1, extract v12/v13`.
    public static var summary: String { "\(classifyVersion), \(windowsVersion), extract v12/v13" }
}
