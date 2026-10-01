import Foundation
import GRDB
@testable import MemorriCore

/// In-memory `SettingsStore` for tests.
final class FakeSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    private var ints: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var dates: [String: Date] = [:]

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? defaultValue
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func int(forKey key: String) -> Int? { lock.lock(); defer { lock.unlock() }; return ints[key] }
    func setInt(_ value: Int, forKey key: String) { lock.lock(); defer { lock.unlock() }; ints[key] = value }
    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[key] }
    func setString(_ value: String, forKey key: String) { lock.lock(); defer { lock.unlock() }; strings[key] = value }
    func date(forKey key: String) -> Date? { lock.lock(); defer { lock.unlock() }; return dates[key] }
    func setDate(_ value: Date, forKey key: String) { lock.lock(); defer { lock.unlock() }; dates[key] = value }

    func rawValue(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
}

/// Screen Recording checker whose answer the test controls.
final class FakeScreenRecordingChecker: ScreenRecordingChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool

    init(granted: Bool) { self.granted = granted }

    func set(granted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.granted = granted
    }

    func isGranted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return granted
    }
}

/// Time source the test moves by hand.
final class FakeTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ seconds: TimeInterval = 0) { current = Date(timeIntervalSinceReferenceDate: seconds) }

    func set(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = Date(timeIntervalSinceReferenceDate: seconds)
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// Counts feedback calls.
final class FakeFeedback: FeedbackPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var flashes = 0
    private var sounds = 0
    private var warningFlashes = 0
    private var warningSounds = 0

    var flashCount: Int { lock.lock(); defer { lock.unlock() }; return flashes }
    var soundCount: Int { lock.lock(); defer { lock.unlock() }; return sounds }
    var warningFlashCount: Int { lock.lock(); defer { lock.unlock() }; return warningFlashes }
    var warningSoundCount: Int { lock.lock(); defer { lock.unlock() }; return warningSounds }

    func flashIcon() async { bump(\.flashes) }
    func playSound() async { bump(\.sounds) }
    func flashWarning() async { bump(\.warningFlashes) }
    func playWarningSound() async { bump(\.warningSounds) }

    private func bump(_ counter: ReferenceWritableKeyPath<FakeFeedback, Int>) {
        lock.lock(); defer { lock.unlock() }
        self[keyPath: counter] += 1
    }
}

/// Counts how often the onboarding window was requested.
final class OnboardingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

/// System-shortcut checker with a fixed list of reserved combos.
struct FakeSystemShortcuts: SystemShortcutChecking {
    var reserved: Set<KeyCombo> = []
    func isReservedBySystem(_ combo: KeyCombo) -> Bool { reserved.contains(combo) }
}

// MARK: Synthetic images

import CoreGraphics

/// A solid-colour image with a simple gradient so it is not trivially compressible.
func makeTestImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in stride(from: 0, to: width, by: 16) {
        ctx.setFillColor(CGColor(red: Double(x) / Double(width), green: 0.4, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 16, height: height))
    }
    return ctx.makeImage()!
}

// MARK: Temporary directories

/// A fresh directory under the system temp folder, removed by `cleanUp()`.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorri-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

// MARK: Storage records

func makeEventRecord(id: String = UUID().uuidString, at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
                     trigger: String = "shortcut", status: String = "complete",
                     failureReason: String? = nil, displayCount: Int = 1) -> CaptureEventRecord {
    CaptureEventRecord(id: id, capturedAt: date, trigger: trigger, status: status,
                       failureReason: failureReason, displayCount: displayCount)
}

func makeImageRecord(eventID: String, id: String = UUID().uuidString, displayID: Int = 1) -> CaptureImageRecord {
    CaptureImageRecord(id: id, eventId: eventID, displayId: displayID, displayName: "Test display",
                       pixelWidth: 3440, pixelHeight: 1440, scale: 1.0,
                       fullPath: "captures/2027-01/\(eventID)/\(id)-full.heic",
                       modelPath: "captures/2027-01/\(eventID)/\(id)-model.heic",
                       modelWidth: 2048, modelHeight: 857, fullBytes: 1000, modelBytes: 500, missing: false)
}

// MARK: Capture pipeline fakes

import CoreGraphics

/// Display capturer that returns a scripted result, optionally after a delay.
final class FakeDisplayCapturer: DisplayCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DisplayCaptureResult, CaptureFailure>
    private var calls = 0
    let delay: Duration

    init(displays: [CapturedDisplay] = [], failedDisplayCount: Int = 0, delay: Duration = .zero) {
        result = .success(DisplayCaptureResult(displays: displays, failedDisplayCount: failedDisplayCount))
        self.delay = delay
    }

    init(failure: CaptureFailure) {
        result = .failure(failure)
        delay = .zero
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    private func recordCall() -> Result<DisplayCaptureResult, CaptureFailure> {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return result
    }

    func captureAllDisplays() async throws -> DisplayCaptureResult {
        let current = recordCall()
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try current.get()
    }
}

func makeDisplay(id: UInt32 = 1, width: Int = 3440, height: Int = 1440) -> CapturedDisplay {
    CapturedDisplay(displayID: id, name: "Display \(id)", image: makeTestImage(width: width, height: height), scale: 1)
}

struct FakeDiskSpace: DiskSpaceChecking {
    var free: Int64 = 50 * 1_073_741_824
    func freeBytes(at url: URL) throws -> Int64 { free }
}

struct FailingEncoder: ImageEncoding {
    func encodeFullResolution(_ image: CGImage) throws -> EncodedPicture { throw ImageEncodingError.cannotEncode }
    func encodeAnalysisCopy(_ image: CGImage, longEdge: Int) throws -> EncodedPicture { throw ImageEncodingError.cannotEncode }
}

struct FailingStore: CaptureStoring {
    func insert(event: CaptureEventRecord, images: [CaptureImageRecord], windows: [String: [WindowInfo]]) throws { throw CocoaError(.fileWriteUnknown) }
}

/// Capture runner that returns a scripted outcome and records how it was called.
final class FakeCaptureRunner: CaptureRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CaptureOutcome?
    private var triggers: [CaptureTrigger] = []

    init(outcome: CaptureOutcome? = .complete(displays: 1)) { self.outcome = outcome }

    var calls: [CaptureTrigger] { lock.lock(); defer { lock.unlock() }; return triggers }

    func run(trigger: CaptureTrigger) async -> CaptureOutcome? { record(trigger) }

    private func record(_ trigger: CaptureTrigger) -> CaptureOutcome? {
        lock.lock(); defer { lock.unlock() }
        triggers.append(trigger)
        return outcome
    }
}

// MARK: Ollama fakes

/// Transport that returns scripted answers per path and records every request.
final class FakeOllamaTransport: OllamaTransport, @unchecked Sendable {
    enum Reply {
        case json(String)                              // HTTP 200
        case status(Int, String = "{}")
        case fail(OllamaTransportError)
    }

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var sent: [OllamaHTTPRequest] = []
    var delay: Duration = .zero

    func set(_ path: String, _ reply: Reply) { lock.lock(); replies[path] = reply; lock.unlock() }

    var requests: [OllamaHTTPRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    func requests(to path: String) -> [OllamaHTTPRequest] { requests.filter { $0.path == path } }

    func send(_ request: OllamaHTTPRequest) async throws -> OllamaHTTPResponse {
        let reply = record(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        switch reply {
        case .json(let text): return OllamaHTTPResponse(status: 200, body: Data(text.utf8))
        case .status(let code, let text): return OllamaHTTPResponse(status: code, body: Data(text.utf8))
        case .fail(let error): throw error
        case nil: return OllamaHTTPResponse(status: 404, body: Data(#"{"error":"not scripted"}"#.utf8))
        }
    }

    private func record(_ request: OllamaHTTPRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        return replies[request.path]
    }
}

// MARK: Analysis fakes

import ImageIO

/// HEIC bytes of a synthetic picture, like the stored analysis copies.
func makeHEICData(width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, makeTestImage(width: width, height: height), nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Picture provider with a fixed set of stored pictures; a missing id is "no longer stored".
final class FakePictureProvider: AnalysisPictureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var pictures: [String: StoredPicture]

    init(_ pictures: [String: StoredPicture] = [:]) { self.pictures = pictures }

    func set(_ picture: StoredPicture?, for id: String) { lock.lock(); pictures[id] = picture; lock.unlock() }

    func analysisPicture(imageID: String) throws -> StoredPicture? {
        lock.lock(); defer { lock.unlock() }
        return pictures[imageID]
    }
}

// MARK: Queue fakes

/// Sleeper whose sleeps last until the test releases them; records what was asked for.
final class FakeQueueSleeper: QueueSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<UUID> = []
    private var asked: [Duration] = []

    var requested: [Duration] { lock.lock(); defer { lock.unlock() }; return asked }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if !register(id, continuation, duration) { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Ends every sleep that is waiting now.
    func releaseAll() {
        let all = drain()
        for continuation in all { continuation.resume() }
    }

    private func register(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>, _ duration: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        asked.append(duration)
        if cancelledEarly.remove(id) != nil { return false }
        waiters[id] = continuation
        return true
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        if continuation == nil { cancelledEarly.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func drain() -> [CheckedContinuation<Void, Error>] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(waiters.values)
        waiters = [:]
        return all
    }
}

/// Server status the test sets; counts how often it was asked.
final class FakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ServerStatus
    private var asked = 0

    init(_ status: ServerStatus = .reachable(version: "0.34.4")) { current = status }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return asked }
    func set(_ status: ServerStatus) { lock.lock(); current = status; lock.unlock() }
    func ask() -> ServerStatus { lock.lock(); defer { lock.unlock() }; asked += 1; return current }
}

/// A door the test opens; `wait` returns at once when it is already open.
final class FakeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) { isOpen = open }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiters
        waiters = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !add(continuation) { continuation.resume() }
        }
    }

    private func add(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isOpen { return false }
        waiters.append(continuation)
        return true
    }
}

/// Job runner with a scripted outcome per job; tracks how many ran at once and in which order.
final class FakeJobRunner: AnalysisJobRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var started: [String] = []
    private var attempts: [(String, Int)] = []
    private var outcome: @Sendable (AnalysisJobRecord, Int) -> JobOutcome
    let latch: FakeLatch
    let delay: Duration

    init(latch: FakeLatch = FakeLatch(open: true), delay: Duration = .zero,
         outcome: @escaping @Sendable (AnalysisJobRecord, Int) -> JobOutcome = { _, _ in .success }) {
        self.latch = latch
        self.delay = delay
        self.outcome = outcome
    }

    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var activeNow: Int { lock.lock(); defer { lock.unlock() }; return active }
    var order: [String] { lock.lock(); defer { lock.unlock() }; return started }
    var attemptLog: [(String, Int)] { lock.lock(); defer { lock.unlock() }; return attempts }
    func setOutcome(_ value: @escaping @Sendable (AnalysisJobRecord, Int) -> JobOutcome) {
        lock.lock(); outcome = value; lock.unlock()
    }

    func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        begin(job, attempt)
        await latch.wait()
        if delay > .zero { try? await Task.sleep(for: delay) }
        return finish(job, attempt)
    }

    private func begin(_ job: AnalysisJobRecord, _ attempt: Int) {
        lock.lock(); defer { lock.unlock() }
        active += 1
        maximum = max(maximum, active)
        started.append(job.id)
        attempts.append((job.id, attempt))
    }

    private func finish(_ job: AnalysisJobRecord, _ attempt: Int) -> JobOutcome {
        lock.lock(); defer { lock.unlock() }
        active -= 1
        return outcome(job, attempt)
    }
}

/// Polls until the condition holds (real time), for tests that wait on a background loop.
/// Waits for a condition; a passing test returns at once, so the long limit costs nothing. A full parallel run was seen to delay the queue's task by several seconds.
func waitUntil(timeout: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: Pipeline fakes (spec 004)

/// A model that answers by the property names of the requested schema, records every request and can
/// delay or fail. No server is involved.
final class FakeModelChatting: ModelChatting, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var failure: (any Error)?
    private var sent: [ChatRequest] = []
    private var thinking: String?
    var delay: Duration = .zero

    /// `key` is a property name that appears in the schema, for example `screen_kind` or `findings`.
    func answer(whenSchemaHas key: String, _ content: String) { lock.lock(); answers[key] = content; lock.unlock() }
    func failWith(_ error: (any Error)?) { lock.lock(); failure = error; lock.unlock() }
    func setThinking(_ text: String?) { lock.lock(); thinking = text; lock.unlock() }

    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    var callCount: Int { requests.count }
    func requests(whereSchemaHas key: String) -> [ChatRequest] { requests.filter { Self.properties(of: $0.schema).contains(key) } }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        let (content, error, think) = record(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return ChatResponse(content: content ?? "", thinking: think, doneReason: "stop", totalDurationNanoseconds: nil,
                            loadDurationNanoseconds: nil, promptEvalNanoseconds: nil, evalCount: nil)
    }

    func requestJSON(for request: ChatRequest) -> String {
        OllamaClient(transport: FakeOllamaTransport()).requestJSON(for: request)
    }

    private func record(_ request: ChatRequest) -> (String?, (any Error)?, String?) {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        let keys = Self.properties(of: request.schema)
        let content = answers.first { keys.contains($0.key) }?.value
        return (content, failure, thinking)
    }

    static func properties(of schema: JSONValue) -> Set<String> {
        if case .object(let root) = schema, case .object(let props)? = root["properties"] { return Set(props.keys) }
        return []
    }
}

/// A temporary database with one stored capture: the full-resolution and analysis pictures are real HEIC
/// files in the capture folder, so the real picture providers can read them.
struct PipelineFixture {
    let temp: TempDirectory
    let paths: AppPaths
    let database: StorageDatabase
    let captures: CaptureStore
    let event: CaptureEventRecord
    let image: CaptureImageRecord
    var imageID: String { image.id }
    func cleanUp() { temp.cleanUp() }
}

func makePipelineFixture(fullSize: (Int, Int) = (1200, 600), modelSize: (Int, Int) = (600, 300),
                         windows: [WindowInfo] = []) throws -> PipelineFixture {
    let temp = TempDirectory()
    let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
    try paths.prepare()
    guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
    let store = CaptureStore(database: database)
    let event = makeEventRecord()
    var image = makeImageRecord(eventID: event.id)
    image.pixelWidth = fullSize.0; image.pixelHeight = fullSize.1
    image.modelWidth = modelSize.0; image.modelHeight = modelSize.1
    for (path, size) in [(image.fullPath, fullSize), (image.modelPath, modelSize)] {
        let url = paths.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeHEICData(width: size.0, height: size.1).write(to: url)
    }
    try store.insert(event: event, images: [image], windows: windows.isEmpty ? [:] : [image.id: windows])
    return PipelineFixture(temp: temp, paths: paths, database: database, captures: store, event: event, image: image)
}

/// A text recogniser that returns scripted lines, or fails, and counts its calls.
final class FakeTextRecogniser: TextRecogniser, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [RecognisedLine]
    private var failure: Error?
    private var sizes: [(Int, Int)] = []

    init(lines: [RecognisedLine] = [], failWith error: Error? = nil) {
        self.scripted = lines
        self.failure = error
    }

    var callCount: Int { lock.withLock { sizes.count } }
    var imageSizes: [(Int, Int)] { lock.withLock { sizes } }

    private func next(_ image: CGImage) throws -> [RecognisedLine] {
        try lock.withLock {
            sizes.append((image.width, image.height))
            if let failure { throw failure }
            return scripted
        }
    }

    func recognise(_ image: CGImage) async throws -> [RecognisedLine] { try next(image) }
}

/// Remembers which pictures were handed to the analysis queue.
final class FakeEnqueuer: AnalysisEnqueuing, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []

    var calls: [[String]] { lock.withLock { batches } }

    private func add(_ ids: [String]) { lock.withLock { batches.append(ids) } }

    func enqueueAnalysis(imageIDs: [String]) async { add(imageIDs) }
}

extension Item {
    /// A plain active appointment for tests; change what a test needs.
    static func sample(id: String = UUID().uuidString, kind: FindingKind = .appointment, title: String = "Daily standup",
                       start: Date? = Date(timeIntervalSince1970: 1_791_961_200), contextID: String? = nil) -> Item {
        Item(id: id, kind: kind, contextID: contextID, title: title, start: start, timezone: "UTC", confidence: 0.8,
             firstSeen: Date(timeIntervalSince1970: 1_791_900_000), lastSeen: Date(timeIntervalSince1970: 1_791_900_000))
    }
}

// MARK: Reconciliation fakes (spec 005)

/// A meaning judge whose vectors and answers the test scripts, counting the calls it gets. A title with no scripted vector has an
/// empty one, which reconciliation reads as "unknown".
final class FakeMeaningJudge: MeaningJudging, @unchecked Sendable {
    enum Mode { case ok, unavailable, throwing }

    private let lock = NSLock()
    private var mode: Mode
    private var vectors: [String: [Float]] = [:]
    private var answers: [String: Double] = [:]
    private var fallback: Double
    private var embedded: [[String]] = []
    private var judged: [(JudgedSighting, JudgedSighting)] = []

    init(mode: Mode = .ok, defaultAnswer: Double = 0) { self.mode = mode; self.fallback = defaultAnswer }

    func setMode(_ value: Mode) { lock.lock(); mode = value; lock.unlock() }
    func setVector(_ vector: [Float], for normalisedTitle: String) { lock.lock(); vectors[normalisedTitle] = vector; lock.unlock() }
    /// The probability of "same event" for a pair of normalised titles, in either order.
    func setAnswer(_ p: Double, _ a: String, _ b: String) { lock.lock(); answers[[a, b].sorted().joined(separator: "|")] = p; lock.unlock() }

    var embedCalls: [[String]] { lock.lock(); defer { lock.unlock() }; return embedded }
    var judgeCalls: [(JudgedSighting, JudgedSighting)] { lock.lock(); defer { lock.unlock() }; return judged }

    var canEmbed: Bool { get async { lock.withLock { mode != .unavailable } } }
    var canJudge: Bool { get async { lock.withLock { mode != .unavailable } } }

    func embeddings(for titles: [String]) async throws -> [[Float]] {
        try lock.withLock {
            if mode == .unavailable { throw MeaningJudgeError.unavailable }
            embedded.append(titles)
            if mode == .throwing { throw OllamaClientError.timedOut }
            return titles.map { vectors[$0] ?? [] }
        }
    }

    func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double {
        try lock.withLock {
            if mode == .unavailable { throw MeaningJudgeError.unavailable }
            judged.append((a, b))
            if mode == .throwing { throw OllamaClientError.timedOut }
            let key = [TitleNormaliser.normalise(a.title), TitleNormaliser.normalise(b.title)].sorted().joined(separator: "|")
            return answers[key] ?? fallback
        }
    }
}

/// A database with several pictures and contexts, and a way to store the findings of an analysis the way the job does.
final class ReconcileFixture {
    let base: PipelineFixture
    var database: StorageDatabase { base.database }
    private(set) var imageIDs: [String]

    init() throws {
        base = try makePipelineFixture()
        imageIDs = [base.imageID]
    }

    func cleanUp() { base.cleanUp() }

    /// 2026-10-14 07:00 UTC, a Wednesday: the day the sample appointments are on.
    static let nine = Date(timeIntervalSince1970: 1_791_961_200)
    static func minutes(_ n: Int, after date: Date = ReconcileFixture.nine) -> Date { date.addingTimeInterval(Double(n) * 60) }

    func addContext(_ id: String, _ name: String, timezone: String? = "UTC") throws {
        try database.pool.write {
            try $0.execute(sql: "INSERT INTO contexts (id, name, timezone, created_at, updated_at) VALUES (?, ?, ?, datetime('now'), datetime('now'))",
                           arguments: [id, name, timezone])
        }
    }

    /// A new picture (its own capture event) taken at `date`; returns its id.
    @discardableResult
    func addPicture(at date: Date, display: String = "Test display") throws -> String {
        let event = makeEventRecord(at: date)
        var image = makeImageRecord(eventID: event.id)
        image.displayName = display
        try base.captures.insert(event: event, images: [image])
        imageIDs.append(image.id)
        return image.id
    }

    func finding(_ title: String, start: Date? = ReconcileFixture.nine, end: Date? = nil, kind: FindingKind = .appointment, allDay: Bool = false,
                 due: Date? = nil, confidence: Double = 0.8, inferredEnd: Bool = false, people: [String] = [], place: String? = nil,
                 cited: [Int] = [1], timezone: String = "UTC", id: String = UUID().uuidString) -> Finding {
        var provenance: [String: FieldProvenance] = [:]
        if start != nil { provenance["start"] = FieldProvenance(origin: .read, rule: "explicit-date") }
        if end != nil { provenance["end"] = inferredEnd ? FieldProvenance(origin: .inferred, rule: "default-duration") : FieldProvenance(origin: .read, rule: "explicit-time") }
        return Finding(id: id, kind: kind, title: title, allDay: allDay, start: start, end: end, due: due, timezone: timezone, people: people,
                       place: place, citedLines: cited, confidence: confidence, provenance: provenance)
    }

    /// Stores an analysis the way `AnalysisResultStore.save` does, replacing the picture's earlier one, with the context decision.
    func save(_ findings: [Finding], imageID: String? = nil, contextID: String? = nil, contextSource: ContextDecision.Source = .auto) throws {
        let classification = ClassificationResult(kind: .calendarWeek, confidence: 0.9, application: "Outlook", platformLook: "windows",
                                                  isRemote: false, remoteClient: "", theme: "light", calendarName: "")
        let decision = contextID == nil ? ContextDecision.unassigned : ContextDecision(contextID: contextID, source: contextSource, score: 5)
        let result = AnalysisResult(lines: [], classification: classification, findings: findings, decision: decision,
                                    timezone: TimeZone(identifier: "UTC")!, model: "fake", pictureLongEdge: 2048)
        try AnalysisResultStore(database: database).save(result, imageID: imageID ?? base.imageID, runID: nil, at: Date(timeIntervalSince1970: 1_791_950_000))
    }

    func count(_ table: String) throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    /// Everything an undo has to put back, as sorted text lines (times of last change left out).
    func snapshot() throws -> [String] {
        try read { db in
            func lines(_ tag: String, _ sql: String) throws -> [String] {
                try Row.fetchAll(db, sql: sql).map { row in tag + "|" + row.databaseValues.map { "\($0)" }.joined(separator: "|") }
            }
            var all: [String] = []
            all += try lines("item", """
                SELECT id, kind, family, status, merged_into, context_id, title, all_day, start_at, end_at, due_at, remind_at, timezone, day_key,
                       people_json, place, notes, confidence, user_touched, first_seen, last_seen,
                       needs_review, review_reasons_json, approved_at, approved_values_json FROM items
                """)
            all += try lines("sighting", "SELECT id, item_id, image_id, title FROM sightings")
            all += try lines("observation", "SELECT id, item_id, sighting_id, field, value_json, source FROM observations")
            all += try lines("lock", "SELECT item_id, field, observation_id FROM field_locks")
            all += try lines("alias", "SELECT item_id, normalised, title FROM item_aliases")
            all += try lines("apart", "SELECT item_a, item_b FROM keep_apart")
            all += try lines("possible", "SELECT item_a, item_b FROM possible_duplicates")
            return all.sorted()
        }
    }

    /// What differs between two snapshots, for a readable failure.
    static func difference(_ a: [String], _ b: [String]) -> String {
        let onlyA = Set(a).subtracting(b).sorted(), onlyB = Set(b).subtracting(a).sorted()
        return onlyA.isEmpty && onlyB.isEmpty ? "" : "only in first:\n" + onlyA.joined(separator: "\n") + "\nonly in second:\n" + onlyB.joined(separator: "\n")
    }

    // Plain, non-async wrappers: inside an async test `pool.read` would pick the async overload.
    func read<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try withoutActuallyEscaping(body) { try database.pool.read($0) } }
    func write<T>(_ body: (GRDB.Database) throws -> T) throws -> T { try withoutActuallyEscaping(body) { try database.pool.write($0) } }
}
