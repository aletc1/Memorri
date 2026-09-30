# Core Interfaces: MemorriCore (spec 003)

Signatures only; bodies are written test-first. All types are `Sendable`. New files live under `Inference/` and `Analysis/`; the database types extend `Storage/`.

```swift
// MARK: The only place that may touch the network (ADR 0011)

public struct LoopbackAddress: Sendable, Equatable {
    public static let standard: LoopbackAddress                  // http://localhost:11434
    /// nil unless scheme is http/https, host is exactly localhost, 127.0.0.1 or ::1,
    /// no user info, path empty or "/" (FR-002).
    public init?(_ text: String)
    public var url: URL { get }
    public var text: String { get }
}

public struct OllamaHTTPRequest: Sendable {
    public enum Method: Sendable { case get, post }
    public let method: Method
    public let path: String                   // "/api/version", "/api/tags", "/api/show", "/api/chat"
    public let body: Data?
    public let timeout: TimeInterval
}
public struct OllamaHTTPResponse: Sendable { public let status: Int; public let body: Data }

public enum OllamaTransportError: Error, Sendable, Equatable {
    case unreachable          // connection refused or no route
    case timedOut
    case redirectRefused      // a redirect is never followed
    case other(String)
}

public protocol OllamaTransport: Sendable {
    func send(_ request: OllamaHTTPRequest) async throws -> OllamaHTTPResponse
}

/// The real transport: URLSession, built only from a LoopbackAddress, re-checks the host of every
/// request, refuses redirects. The only file the no-network scan allows to use URLSession.
public struct OllamaURLSessionTransport: OllamaTransport {
    public init(address: LoopbackAddress)
}

// MARK: Client (plain requests and answers, no policy)

public struct InstalledModel: Sendable, Equatable {
    public let name: String
    public let readsImages: Bool              // capabilities contains "vision"
    public let thinks: Bool                   // capabilities contains "thinking"
}

public enum ThinkSetting: String, Sendable, CaseIterable { case off, low, medium, high }

public enum ThinkWireValue: Sendable, Equatable {
    case bool(Bool), level(String), omitted
    /// A model that does not think gives `.omitted` (no `think` field); `off` gives `.bool(false)`;
    /// a level gives `.level` when `acceptsLevels`, else `.bool(true)`.
    public static func make(setting: ThinkSetting, modelThinks: Bool, acceptsLevels: Bool) -> ThinkWireValue
    /// From the spike (ADR 0013): a small built-in rule by model name (default: boolean only).
    public static func acceptsLevels(modelName: String) -> Bool
}

public struct ChatRequest: Sendable {
    public let model: String
    public let systemPrompt: String?
    public let prompt: String
    public let picture: Data                  // sent as base64; never stored in request_json
    public let picturePlaceholder: String     // "[picture <id> 2048x857]"
    public let schema: JSONValue              // goes to "format" when useNativeFormat, else is described in the prompt
    public let useNativeFormat: Bool          // from the spike decision (ADR 0013); false = schema in the prompt, no "format"
    public let think: ThinkWireValue          // from ThinkSetting + model (see make)
    public let temperature: Double            // 0
    public let timeout: TimeInterval
}

public struct ChatResponse: Sendable, Equatable {
    public let content: String
    public let thinking: String?
    public let doneReason: String?
    public let totalDurationNanoseconds: Int64?
    public let loadDurationNanoseconds: Int64?
    public let promptEvalNanoseconds: Int64?
    public let evalCount: Int?
}

public enum OllamaClientError: Error, Sendable, Equatable {
    case serverError(Int), requestRejected, badResponse, timedOut, unreachable, redirectRefused
}

public struct OllamaClient: Sendable {
    public init(transport: any OllamaTransport)
    public func version() async throws -> String
    public func models() async throws -> [InstalledModel]     // /api/tags, /api/show when capabilities are absent
    public func chat(_ request: ChatRequest) async throws -> ChatResponse
    /// The request exactly as sent, with the picture replaced by `picturePlaceholder` (run record).
    public func requestJSON(for request: ChatRequest) -> String
}

// MARK: JSON values and schema validation

public enum JSONValue: Sendable, Equatable, Codable { case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue]) }

public enum SchemaValidationError: Error, Sendable, Equatable { case notJSON, mismatch(String) }

/// Checks an answer against the subset of JSON Schema that our schemas use: type (object, string,
/// boolean, integer, number, array), properties, required, enum, items, additionalProperties false.
public enum SchemaValidator {
    public static func validate(_ answer: String, against schema: JSONValue) -> Result<JSONValue, SchemaValidationError>
}

// MARK: Settings

public struct OllamaSettings: Sendable {
    public static let defaultTimeoutSeconds = 300
    public static let timeoutRange = 10...1800
    public static let recommendedModel = "qwen3.8:27b-mlx"
    public init(store: any SettingsStore)
    public var address: LoopbackAddress { get }
    public func setAddress(_ text: String) -> Bool           // false and unchanged for a non-local address (FR-002)
    public var model: String? { get }
    public func setModel(_ name: String?)
    public var think: ThinkSetting { get }
    public func setThink(_ value: ThinkSetting)
    public var timeoutSeconds: Int { get }
    public func setTimeoutSeconds(_ value: Int) -> Bool      // false and unchanged when outside 10...1800 (FR-009)
    public var analysisPaused: Bool { get }
    public func setAnalysisPaused(_ value: Bool)
}

// MARK: Server status

public enum ServerStatus: Sendable, Equatable {
    case unchecked
    case reachable(version: String)
    case notReachable
    case timedOut
    case noVisionModel
    case noModelChosen
    case modelMissing(String)
}

public struct ModelList: Sendable, Equatable {
    public let usable: [InstalledModel]       // readsImages only
    public let hiddenCount: Int               // installed models that cannot read images
}

public actor OllamaService {
    public static let checkTimeout: TimeInterval = 5
    public init(settings: OllamaSettings, makeTransport: @escaping @Sendable (LoopbackAddress) -> any OllamaTransport,
                time: any TimeSource = SystemTimeSource(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })
    /// Defined in `OllamaURLSessionTransport.swift` so no other file names the session type.
    public static func live(settings: OllamaSettings) -> OllamaService
    public private(set) var status: ServerStatus { get }
    /// One check at a time; a call made while one runs joins it (FR-004).
    @discardableResult public func check() async -> ServerStatus
    public func modelList() async throws -> ModelList
    /// Picks qwen3.8:27b-mlx when nothing is chosen and it is installed (FR-006).
    public func applyDefaultModelIfNeeded() async
    public func statusUpdates() -> AsyncStream<ServerStatus>
    public func client() -> OllamaClient     // for the current address
}

// MARK: Jobs and the durable queue (ADR 0012)

public struct AnalysisJobRecord: Sendable, Equatable { /* columns of analysis_jobs */ }
public struct ModelRunRecord: Sendable, Equatable { /* columns of model_runs */ }

public protocol AnalysisJobStoring: Sendable {
    func enqueue(_ job: AnalysisJobRecord) throws
    func job(id: String) throws -> AnalysisJobRecord?
    func latestRun(jobID: String) throws -> ModelRunRecord?   // newest attempt, for the result line
    @discardableResult func recoverRunningJobs() throws -> Int   // running -> waiting at start; returns how many
    func nextRunnable(now: Date) throws -> AnalysisJobRecord? // waiting, not_before passed, oldest first
    func nextWakeUp(now: Date) throws -> Date?                // earliest future not_before
    func markRunning(id: String, now: Date) throws
    func markFinished(id: String, now: Date) throws
    func markWaiting(id: String, failedAttempts: Int, notBefore: Date?, now: Date) throws
    func markFailed(id: String, failedAttempts: Int, reason: String, now: Date) throws
    func record(run: ModelRunRecord) throws
    func counts() throws -> JobCounts
    func recentFailures(limit: Int) throws -> [AnalysisJobRecord]
    func retryFailed(now: Date) throws -> Int
    func clearFinished() throws -> Int                        // also deletes image-less runs of those jobs
}
public struct AnalysisStore: AnalysisJobStoring { public init(database: StorageDatabase) }

public struct JobCounts: Sendable, Equatable { public let waiting, running, finished, failed: Int }

public enum JobOutcome: Sendable, Equatable {
    case success
    case transient(String)                    // timeout, lost connection, server error, invalid answer
    case permanent(String)                    // picture no longer stored, request rejected
    case serverUnavailable                    // gate closed mid-job: no attempt used
}

public protocol AnalysisJobRunning: Sendable {
    /// Runs one attempt (attempt is 1...3) and records its model run.
    func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome
}

public struct RetryPolicy: Sendable, Equatable {
    public static let standard: RetryPolicy                   // 3 attempts, waits [10 s, 60 s]
    public let maxAttempts: Int
    public let waits: [TimeInterval]
}

public struct QueueProgress: Sendable, Equatable {
    public let counts: JobCounts
    public let paused: Bool
    public static func holdingReason(for status: ServerStatus) -> String?
    public let holdingReason: String?         // mapped from ServerStatus: notReachable/timedOut -> "Ollama not reachable"; noVisionModel/modelMissing -> "model not installed"; noModelChosen -> "choose a model"
}

public actor AnalysisQueue {
    public init(store: any AnalysisJobStoring, runner: any AnalysisJobRunning,
                ready: @escaping @Sendable () async -> ServerStatus,
                settings: OllamaSettings, policy: RetryPolicy = .standard,
                time: any TimeSource = SystemTimeSource(), sleeper: any QueueSleeping)
    public func start() async                 // recovers running jobs, then runs the loop
    public func stop() async
    @discardableResult public func enqueueTest(imageID: String?) throws -> String   // nil = built-in sample; returns the job id
    public func progress() -> QueueProgress
    public func nudge()                       // wake the loop (settings changed, resume, retry)
    public func pause(_ paused: Bool)
    public func retryFailed() throws
    public func clearFinished() throws
    public func progressUpdates() -> AsyncStream<QueueProgress>
}

public protocol QueueSleeping: Sendable { func sleep(for: Duration) async throws }   // real and fake
public struct RealQueueSleeper: QueueSleeping { public init() }

/// Exact menu texts (FR-016). Pure.
public enum AnalysisLine {
    public static func text(for progress: QueueProgress) -> String
}

// MARK: The test job and the built-in picture

/// The line under "Test the model": `Answer valid in 12.4 s: "…"` or `Failed: <reason>`; nil while unfinished.
public enum ModelTestResultLine {
    public static func text(job: AnalysisJobRecord, run: ModelRunRecord?) -> String?
}

public enum ModelTestJob {
    public static let thinkingMarker = "\n\n[thinking]\n"    // separates the answer from thinking text in raw_answer
    public static let promptVersion = "test-v1"
    public static let schemaVersion = "test-v1"
    public static let schema: JSONValue       // { description: string, contains_text: boolean, text_sample: string }, all required
    public static let prompt: String
}

public struct ModelTestJobRunner: AnalysisJobRunning {
    public init(service: OllamaService, store: any AnalysisJobStoring, pictures: any AnalysisPictureProviding,
                settings: OllamaSettings, time: any TimeSource)
}

public struct StoredPicture: Sendable, Equatable {
    public let data: Data; public let width: Int; public let height: Int
    public var longEdge: Int { max(width, height) }
}

public protocol AnalysisPictureProviding: Sendable {
    /// The analysis copy of a stored picture (HEIC), or nil when it is no longer stored.
    func analysisPicture(imageID: String) throws -> StoredPicture?
}

/// Reads analysis copies from the capture folder; lives in the core package, not in the app.
public struct StoredPictureProvider: AnalysisPictureProviding { public init(paths: AppPaths, store: CaptureStore) }

/// The server rejects HEIC (spike), so stored copies are sent as JPEG 0.9.
public enum PictureConverter {
    public static func jpegData(from data: Data) throws -> Data
    public static func jpegData(from image: CGImage) throws -> Data
}

public enum SamplePicture {
    /// A synthetic calendar-like picture with known texts ("Team sync", "10:00"), drawn in code (R10).
    public static func make(longEdge: Int) -> CGImage
    public static let knownTexts: [String]     // the five weekdays, "Team sync" and "10:00"
}
```

## Behaviour the tests pin down

- `LoopbackAddress` accepts `http://localhost:11434`, `http://127.0.0.1:8080`, `http://[::1]:11434` and rejects `http://example.com`, `http://192.168.1.5:11434`, `http://10.0.0.2`, `http://8.8.8.8`, `http://localhost.evil.com`, `http://127.0.0.1.evil.com`, `http://user@evil.com@localhost`, `ftp://localhost`, empty text.
- `OllamaURLSessionTransport` never issues a request for a host other than loopback and fails a redirect with `redirectRefused`.
- `OllamaClient.models()` returns capabilities from `/api/tags`, and asks `/api/show` only for entries without them.
- `ServerStatus` order: unreachable or timed out, then no vision model, then no model chosen, then chosen model missing, then reachable; one check at a time, a second call joins the first; completes within 5 s.
- `OllamaSettings` rejects a timeout outside 10 to 1800 and a non-local address, keeping the previous value.
- `SchemaValidator` accepts an exact match, and rejects: not JSON, missing required key, wrong type, extra key when `additionalProperties` is false, value outside `enum`.
- Queue: never more than one run at once; oldest first; `not_before` respected; transient failure gives waits of 10 s then 60 s and `failed` at 3; permanent fails at once; `serverUnavailable` and a gate that is not `reachable` use no attempt and fail nothing; running jobs recover to `waiting` with attempts unchanged; paused means no new job starts and the running one finishes; resume continues; `retryFailed` and `clearFinished` behave as in the data model.
- A run record is written for every attempt, success or failure, without picture data; deleting a capture deletes its runs, not its queued jobs.
- `AnalysisLine.text` gives exactly the texts in the UI contract for each combination.
