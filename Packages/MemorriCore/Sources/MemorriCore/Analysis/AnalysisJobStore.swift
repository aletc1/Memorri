import Foundation
import GRDB

/// One unit of work for the model. In spec 003 the only kind is `test`.
public struct AnalysisJobRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysis_jobs"

    public enum State: String, Sendable { case waiting, running, finished, failed }

    public var id: String
    public var kind: String
    /// The picture the job needs; nil for the built-in sample. Not a foreign key (data model).
    public var imageId: String?
    public var state: String
    /// Failed attempts so far; a quit during a run does not add one.
    public var attempts: Int
    public var notBefore: Date?
    public var failureReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, kind: String = "test", imageId: String?, state: State = .waiting,
                attempts: Int = 0, notBefore: Date? = nil, failureReason: String? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.imageId = imageId
        self.state = state.rawValue
        self.attempts = attempts
        self.notBefore = notBefore
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case imageId = "image_id"
        case state, attempts
        case notBefore = "not_before"
        case failureReason = "failure_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One attempt of a job. The request is recorded with the picture replaced by a placeholder.
public struct ModelRunRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_runs"

    public enum Outcome: String, Sendable { case success, failed }

    public var id: String
    public var jobId: String
    /// Deleted with the capture it belongs to; nil for runs on the built-in sample.
    public var imageId: String?
    public var attempt: Int
    public var model: String
    public var think: String
    public var temperature: Double
    public var imageLongEdge: Int
    public var promptVersion: String
    public var schemaVersion: String
    public var startedAt: Date
    public var durationMs: Int
    public var outcome: String
    public var failureReason: String?
    public var requestJson: String
    public var rawAnswer: String?

    public init(id: String = UUID().uuidString, jobId: String, imageId: String?, attempt: Int, model: String, think: String,
                temperature: Double, imageLongEdge: Int, promptVersion: String, schemaVersion: String, startedAt: Date,
                durationMs: Int, outcome: Outcome, failureReason: String?, requestJson: String, rawAnswer: String?) {
        self.id = id
        self.jobId = jobId
        self.imageId = imageId
        self.attempt = attempt
        self.model = model
        self.think = think
        self.temperature = temperature
        self.imageLongEdge = imageLongEdge
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.outcome = outcome.rawValue
        self.failureReason = failureReason
        self.requestJson = requestJson
        self.rawAnswer = rawAnswer
    }

    enum CodingKeys: String, CodingKey {
        case id
        case jobId = "job_id"
        case imageId = "image_id"
        case attempt, model, think, temperature
        case imageLongEdge = "image_long_edge"
        case promptVersion = "prompt_version"
        case schemaVersion = "schema_version"
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case outcome
        case failureReason = "failure_reason"
        case requestJson = "request_json"
        case rawAnswer = "raw_answer"
    }
}

public struct JobCounts: Sendable, Equatable {
    public let waiting: Int
    public let running: Int
    public let finished: Int
    public let failed: Int

    public init(waiting: Int, running: Int, finished: Int, failed: Int) {
        self.waiting = waiting
        self.running = running
        self.finished = finished
        self.failed = failed
    }
}

/// What the queue needs from the database (ADR 0012); tests can fake it.
public protocol AnalysisJobStoring: Sendable {
    func enqueue(_ job: AnalysisJobRecord) throws
    func job(id: String) throws -> AnalysisJobRecord?
    /// Puts every `running` job back to `waiting` with its attempts unchanged; returns how many.
    @discardableResult func recoverRunningJobs() throws -> Int
    /// The oldest waiting job whose `not_before` has passed.
    func nextRunnable(now: Date) throws -> AnalysisJobRecord?
    /// The earliest `not_before` still in the future.
    func nextWakeUp(now: Date) throws -> Date?
    func markRunning(id: String, now: Date) throws
    func markFinished(id: String, now: Date) throws
    func markWaiting(id: String, failedAttempts: Int, notBefore: Date?, now: Date) throws
    func markFailed(id: String, failedAttempts: Int, reason: String, now: Date) throws
    func record(run: ModelRunRecord) throws
    func counts() throws -> JobCounts
    func recentFailures(limit: Int) throws -> [AnalysisJobRecord]
    /// Failed jobs back to `waiting` with fresh attempts; returns how many.
    @discardableResult func retryFailed(now: Date) throws -> Int
    /// Deletes finished and failed jobs and the picture-less runs of those jobs; returns the jobs deleted.
    @discardableResult func clearFinished() throws -> Int
}

public struct AnalysisStore: AnalysisJobStoring {
    private let database: StorageDatabase

    public init(database: StorageDatabase) {
        self.database = database
    }

    public func enqueue(_ job: AnalysisJobRecord) throws {
        try database.pool.write { try job.insert($0) }
    }

    public func job(id: String) throws -> AnalysisJobRecord? {
        try database.pool.read { try AnalysisJobRecord.fetchOne($0, key: id) }
    }

    @discardableResult
    public func recoverRunningJobs() throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE analysis_jobs SET state = 'waiting' WHERE state = 'running'")
            return db.changesCount
        }
    }

    public func nextRunnable(now: Date) throws -> AnalysisJobRecord? {
        try database.pool.read { db in
            try AnalysisJobRecord.fetchOne(db, sql: """
                SELECT * FROM analysis_jobs
                WHERE state = 'waiting' AND (not_before IS NULL OR not_before <= ?)
                ORDER BY created_at, id LIMIT 1
                """, arguments: [now])
        }
    }

    public func nextWakeUp(now: Date) throws -> Date? {
        try database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(not_before) FROM analysis_jobs WHERE state = 'waiting' AND not_before > ?",
                              arguments: [now])
        }
    }

    public func markRunning(id: String, now: Date) throws {
        try update(id: id, state: "running", attempts: nil, notBefore: .some(nil), reason: .some(nil), now: now)
    }

    public func markFinished(id: String, now: Date) throws {
        try update(id: id, state: "finished", attempts: nil, notBefore: .some(nil), reason: .some(nil), now: now)
    }

    public func markWaiting(id: String, failedAttempts: Int, notBefore: Date?, now: Date) throws {
        try update(id: id, state: "waiting", attempts: failedAttempts, notBefore: .some(notBefore), reason: .some(nil), now: now)
    }

    public func markFailed(id: String, failedAttempts: Int, reason: String, now: Date) throws {
        try update(id: id, state: "failed", attempts: failedAttempts, notBefore: .some(nil), reason: .some(reason), now: now)
    }

    private func update(id: String, state: String, attempts: Int?, notBefore: Date??, reason: String??, now: Date) throws {
        try database.pool.write { db in
            guard var job = try AnalysisJobRecord.fetchOne(db, key: id) else { return }
            job.state = state
            if let attempts { job.attempts = attempts }
            if let notBefore { job.notBefore = notBefore }
            if let reason { job.failureReason = reason }
            job.updatedAt = now
            try job.update(db)
        }
    }

    public func record(run: ModelRunRecord) throws {
        try database.pool.write { try run.insert($0) }
    }

    public func counts() throws -> JobCounts {
        try database.pool.read { db in
            func count(_ state: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_jobs WHERE state = ?", arguments: [state]) ?? 0
            }
            return JobCounts(waiting: try count("waiting"), running: try count("running"),
                             finished: try count("finished"), failed: try count("failed"))
        }
    }

    public func recentFailures(limit: Int) throws -> [AnalysisJobRecord] {
        try database.pool.read { db in
            try AnalysisJobRecord.fetchAll(db, sql: "SELECT * FROM analysis_jobs WHERE state = 'failed' ORDER BY updated_at DESC, id LIMIT ?",
                                           arguments: [limit])
        }
    }

    @discardableResult
    public func retryFailed(now: Date) throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE analysis_jobs SET state = 'waiting', attempts = 0, not_before = NULL, failure_reason = NULL, updated_at = ?
                WHERE state = 'failed'
                """, arguments: [now])
            return db.changesCount
        }
    }

    @discardableResult
    public func clearFinished() throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM model_runs WHERE image_id IS NULL
                  AND job_id IN (SELECT id FROM analysis_jobs WHERE state IN ('finished', 'failed'))
                """)
            try db.execute(sql: "DELETE FROM analysis_jobs WHERE state IN ('finished', 'failed')")
            return db.changesCount
        }
    }

    /// Every recorded run, oldest first (tests and diagnostics).
    func runs() throws -> [ModelRunRecord] {
        try database.pool.read { try ModelRunRecord.order(Column("started_at"), Column("id")).fetchAll($0) }
    }
}
