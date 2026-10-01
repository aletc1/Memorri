import Foundation
import os

/// Sleeping the loop can do; tests replace it so time can be moved by hand.
public protocol QueueSleeping: Sendable {
    func sleep(for: Duration) async throws
}

public struct RealQueueSleeper: QueueSleeping {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// What the capture step needs to put pictures in the queue, so it does not depend on the queue itself.
public protocol AnalysisEnqueuing: Sendable {
    /// One `analyse` job per picture, in the order given.
    func enqueueAnalysis(imageIDs: [String]) async
}

/// Three attempts per job; after the first failure wait 10 s, after the second 60 s (ADR 0012).
public struct RetryPolicy: Sendable, Equatable {
    public static let standard = RetryPolicy(maxAttempts: 3, waits: [10, 60])

    public let maxAttempts: Int
    public let waits: [TimeInterval]

    public init(maxAttempts: Int, waits: [TimeInterval]) {
        self.maxAttempts = maxAttempts
        self.waits = waits
    }

    /// Wait after the `failedAttempts`-th failure (1-based); the last wait repeats if the list is short.
    func wait(afterFailure failedAttempts: Int) -> TimeInterval {
        guard !waits.isEmpty else { return 0 }
        return waits[min(max(failedAttempts, 1), waits.count) - 1]
    }
}

/// What the menu line and the settings block show. Not stored.
public struct QueueProgress: Sendable, Equatable {
    public let counts: JobCounts
    public let paused: Bool
    /// Why the queue is not running its jobs although it has some: follows the server status.
    public let holdingReason: String?

    public init(counts: JobCounts, paused: Bool, holdingReason: String?) {
        self.counts = counts
        self.paused = paused
        self.holdingReason = holdingReason
    }

    public static func holdingReason(for status: ServerStatus) -> String? {
        switch status {
        case .notReachable, .timedOut: "Ollama not reachable"
        case .noVisionModel, .modelMissing: "model not installed"
        case .noModelChosen: "choose a model"
        case .unchecked, .reachable: nil
        }
    }
}

/// Runs the durable jobs one at a time (ADR 0012). One long-lived loop does all the work, so two
/// jobs can never run together. Jobs live in the database, so a quit or a crash loses nothing.
public actor AnalysisQueue: AnalysisEnqueuing {
    /// How often a closed gate is asked again.
    public static let recheckInterval: Duration = .seconds(30)

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "analysis")

    private let store: any AnalysisJobStoring
    private let runner: any AnalysisJobRunning
    private let ready: @Sendable () async -> ServerStatus
    private let settings: OllamaSettings
    private let policy: RetryPolicy
    private let time: any TimeSource
    private let sleeper: any QueueSleeping
    private let results: AnalysisResultStore?

    private let wake = WakeSignal()
    private var loop: Task<Void, Never>?
    private var holdingReason: String?
    private var lastPublished: QueueProgress?
    private var continuations: [UUID: AsyncStream<QueueProgress>.Continuation] = [:]

    public init(store: any AnalysisJobStoring, runner: any AnalysisJobRunning,
                ready: @escaping @Sendable () async -> ServerStatus,
                settings: OllamaSettings, policy: RetryPolicy = .standard,
                time: any TimeSource = SystemTimeSource(), sleeper: any QueueSleeping = RealQueueSleeper(),
                results: AnalysisResultStore? = nil) {
        self.results = results
        self.store = store
        self.runner = runner
        self.ready = ready
        self.settings = settings
        self.policy = policy
        self.time = time
        self.sleeper = sleeper
    }

    // MARK: Control

    /// Puts jobs that were running at the last quit back to waiting, then starts the loop.
    public func start() async {
        guard loop == nil else { return }
        let recovered = (try? store.recoverRunningJobs()) ?? 0
        Self.logger.info("recovered running=\(recovered)")
        publish()
        loop = Task { await self.runLoop() }
    }

    public func stop() async {
        guard let task = loop else { return }
        loop = nil
        task.cancel()
        await task.value
    }

    /// Returns the id of the new job so the caller can follow it.
    @discardableResult
    public func enqueueTest(imageID: String?) throws -> String {
        let job = AnalysisJobRecord(imageId: imageID, createdAt: time.now())
        try store.enqueue(job)
        publish()
        Task { await wake.fire() }
        return job.id
    }

    /// A job of any kind; the runner registered for the kind does the work. Returns the job id.
    @discardableResult
    public func enqueue(kind: String, imageID: String?) throws -> String {
        let job = AnalysisJobRecord(kind: kind, imageId: imageID, createdAt: time.now())
        try store.enqueue(job)
        publish()
        Task { await wake.fire() }
        return job.id
    }

    /// Wakes the loop: settings changed, resume, retry.
    public func nudge() {
        Task { await wake.fire() }
    }

    /// The running job finishes; nothing new starts while paused. The flag survives a restart.
    public func pause(_ paused: Bool) {
        if settings.analysisPaused != paused {
            if paused { Self.logger.info("queue paused") } else { Self.logger.info("queue resumed by user") }
        }
        settings.setAnalysisPaused(paused)
        publish()
        Task { await wake.fire() }
    }

    public func retryFailed() throws {
        try store.retryFailed(now: time.now())
        publish()
        Task { await wake.fire() }
    }

    public func clearFinished() throws {
        try store.clearFinished()
        publish()
    }

    public func enqueueAnalysis(imageIDs: [String]) {
        var added = 0
        for id in imageIDs {
            // Jobs are created one after another; a fixed clock would give them one creation time, and the
            // store orders equal times by id, so nudge the time to keep the given order.
            if (try? enqueueOrdered(kind: "analyse", imageID: id, offset: added)) != nil { added += 1 }
        }
        if added > 0 {
            Self.logger.info("enqueued analyse=\(added) reason=capture")
            publish()
            Task { await wake.fire() }
        }
    }

    /// One `analyse` job per stored picture that has no analysis and no pending job, oldest first. Returns how many.
    @discardableResult
    public func enqueueBacklog() -> Int {
        guard let ids = try? results?.unanalysedImageIDs(), !ids.isEmpty else { return 0 }
        var added = 0
        for id in ids where (try? enqueueOrdered(kind: "analyse", imageID: id, offset: added)) != nil { added += 1 }
        if added > 0 {
            Self.logger.info("enqueued analyse=\(added) reason=backlog")
            publish()
            Task { await wake.fire() }
        }
        return added
    }

    /// Asks for a fresh analysis of one picture (it replaces the earlier one). Does nothing, and returns false, when the
    /// picture already has a waiting or running analysis job.
    @discardableResult
    public func reanalyse(imageID: String) -> Bool {
        guard (try? store.hasPendingAnalysis(imageID: imageID)) == false,
              (try? enqueueOrdered(kind: "analyse-force", imageID: imageID, offset: 0)) != nil else { return false }
        Self.logger.info("enqueued analyse=1 reason=reanalyse")
        publish()
        Task { await wake.fire() }
        return true
    }

    private func enqueueOrdered(kind: String, imageID: String?, offset: Int) throws {
        let job = AnalysisJobRecord(kind: kind, imageId: imageID, createdAt: time.now().addingTimeInterval(Double(offset) * 0.001))
        try store.enqueue(job)
    }

    public func progress() -> QueueProgress {
        let counts = (try? store.counts()) ?? JobCounts(waiting: 0, running: 0, finished: 0, failed: 0)
        return QueueProgress(counts: counts, paused: settings.analysisPaused, holdingReason: holdingReason)
    }

    /// Emits the current progress first, then every change once.
    public func progressUpdates() -> AsyncStream<QueueProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: QueueProgress.self)
        let current = progress()
        lastPublished = current
        continuation.yield(current)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish() {
        let current = progress()
        guard current != lastPublished else { return }
        lastPublished = current
        for continuation in continuations.values { continuation.yield(current) }
    }

    // MARK: The loop

    private func runLoop() async {
        while !Task.isCancelled {
            if settings.analysisPaused {
                publish()
                await wake.wait()
                continue
            }
            let now = time.now()
            guard let job = try? store.nextRunnable(now: now) else {
                if let next = try? store.nextWakeUp(now: now) {
                    await sleepOrWake(for: next.timeIntervalSince(now))
                } else {
                    await wake.wait()
                }
                continue
            }

            let status = await ready()
            guard status.isUsable else {
                setHolding(Self.reason(for: status))
                await sleepOrWake(for: Self.recheckInterval)
                continue
            }
            setHolding(nil)

            guard !Task.isCancelled, !settings.analysisPaused else { continue }
            let attempt = job.attempts + 1
            do { try store.markRunning(id: job.id, now: time.now()) } catch { continue }
            publish()
            Self.logger.info("job started id=\(job.id, privacy: .public) attempt=\(attempt)")
            let outcome = await runner.run(job, attempt: attempt)
            apply(outcome, to: job)
            publish()

            if outcome == .serverUnavailable { await sleepOrWake(for: Self.recheckInterval) }
        }
    }

    private static func reason(for status: ServerStatus) -> String? { QueueProgress.holdingReason(for: status) }

    private func setHolding(_ reason: String?) {
        if reason != holdingReason {
            if let reason { Self.logger.info("queue holding reason=\(reason, privacy: .public)") } else { Self.logger.info("queue resumed") }
        }
        holdingReason = reason
        publish()
    }

    private func apply(_ outcome: JobOutcome, to job: AnalysisJobRecord) {
        let now = time.now()
        do {
            switch outcome {
            case .success:
                try store.markFinished(id: job.id, now: now)
                Self.logger.info("job finished id=\(job.id, privacy: .public)")
            case .transient(let reason):
                let failed = job.attempts + 1
                if failed >= policy.maxAttempts {
                    try store.markFailed(id: job.id, failedAttempts: failed, reason: reason, now: now)
                    Self.logger.info("job failed id=\(job.id, privacy: .public) reason=\(reason, privacy: .public)")
                } else {
                    try store.markWaiting(id: job.id, failedAttempts: failed,
                                          notBefore: now.addingTimeInterval(policy.wait(afterFailure: failed)), now: now)
                }
            case .permanent(let reason):
                try store.markFailed(id: job.id, failedAttempts: job.attempts, reason: reason, now: now)
                Self.logger.info("job failed id=\(job.id, privacy: .public) reason=\(reason, privacy: .public)")
            case .serverUnavailable:
                try store.markWaiting(id: job.id, failedAttempts: job.attempts, notBefore: nil, now: now)
            }
        } catch {
            Self.logger.error("could not record the outcome of job \(job.id, privacy: .public)")
        }
    }

    /// Returns when the time has passed or something woke the loop, whichever is first.
    private func sleepOrWake(for seconds: TimeInterval) async {
        await sleepOrWake(for: .seconds(max(seconds, 0)))
    }

    private func sleepOrWake(for duration: Duration) async {
        let sleeper = self.sleeper, wake = self.wake
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await sleeper.sleep(for: duration) }
            group.addTask { await wake.wait() }
            await group.next()
            group.cancelAll()
        }
    }
}

/// A one-slot signal: `fire` before `wait` is remembered, and `wait` ends when its task is cancelled.
actor WakeSignal {
    private var pending = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var cancelled: Set<UUID> = []

    func fire() {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume()
        } else {
            pending = true
        }
    }

    func wait() async {
        if pending { pending = false; return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelled.remove(id) != nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiter = (id, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let waiter, waiter.id == id {
            self.waiter = nil
            waiter.continuation.resume()
        } else {
            cancelled.insert(id)
        }
    }
}
