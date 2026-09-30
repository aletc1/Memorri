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
