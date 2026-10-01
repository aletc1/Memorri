import Foundation
import Testing
@testable import MemorriCore

@Suite struct AnalysisQueueTests {
    private struct Rig {
        let queue: AnalysisQueue
        let store: AnalysisStore
        let runner: FakeJobRunner
        let gate: FakeGate
        let sleeper: FakeQueueSleeper
        let time: FakeTimeSource
        let settings: OllamaSettings
        let settingsStore: FakeSettingsStore
        let temp: TempDirectory
        let database: StorageDatabase
    }

    private func makeRig(runner: FakeJobRunner = FakeJobRunner(), gate: FakeGate = FakeGate(),
                         settingsStore: FakeSettingsStore = FakeSettingsStore()) throws -> Rig {
        let temp = TempDirectory()
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        let store = AnalysisStore(database: database)
        let time = FakeTimeSource(1000)
        let sleeper = FakeQueueSleeper()
        let settings = OllamaSettings(store: settingsStore)
        let queue = AnalysisQueue(store: store, runner: runner, ready: { gate.ask() }, settings: settings,
                                  time: time, sleeper: sleeper, results: AnalysisResultStore(database: database))
        return Rig(queue: queue, store: store, runner: runner, gate: gate, sleeper: sleeper, time: time,
                   settings: settings, settingsStore: settingsStore, temp: temp, database: database)
    }

    @discardableResult
    private func add(_ rig: Rig, createdAt: TimeInterval, notBefore: TimeInterval? = nil) throws -> AnalysisJobRecord {
        let job = AnalysisJobRecord(imageId: nil, notBefore: notBefore.map { Date(timeIntervalSinceReferenceDate: $0) },
                                    createdAt: Date(timeIntervalSinceReferenceDate: createdAt))
        try rig.store.enqueue(job)
        return job
    }

    private func state(_ rig: Rig, _ job: AnalysisJobRecord) -> AnalysisJobRecord? { try? rig.store.job(id: job.id) }

    // MARK: order and serial running

    @Test func tenJobsRunOneAtATimeOldestFirst() async throws {
        let runner = FakeJobRunner(delay: .milliseconds(3))
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let jobs = try (0..<10).map { try add(rig, createdAt: 1000 + Double($0)) }
        await rig.queue.start()
        // The jobs take 3 ms each, but under a full parallel run the queue's task was seen to need up to 6.6 s to get its turn (0.4 to 4.4 s on main).
        #expect(await waitUntil(timeout: .seconds(30)) { (try? rig.store.counts().finished) == 10 })
        #expect(runner.maxActive == 1)
        #expect(runner.order == jobs.map(\.id))
        await rig.queue.stop()
    }

    @Test func aJobWithAFutureNotBeforeWaitsForItsTime() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        let later = try add(rig, createdAt: 1000, notBefore: 1100)
        let now = try add(rig, createdAt: 1001)
        await rig.queue.start()
        #expect(await waitUntil { rig.sleeper.pendingCount == 1 })
        #expect(rig.runner.order == [now.id])
        #expect(state(rig, later)?.state == "waiting")
        #expect(rig.sleeper.requested.last == .seconds(100))
        rig.time.set(1100)
        rig.sleeper.releaseAll()
        #expect(await waitUntil { state(rig, later)?.state == "finished" })
        #expect(rig.runner.order == [now.id, later.id])
        await rig.queue.stop()
    }

    // MARK: outcomes

    @Test func transientFailuresWaitTenThenSixtySecondsAndTheThirdFailsTheJob() async throws {
        let runner = FakeJobRunner(outcome: { _, _ in .transient("timed out") })
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()

        #expect(await waitUntil { state(rig, job)?.attempts == 1 && rig.sleeper.pendingCount == 1 })
        #expect(state(rig, job)?.state == "waiting")
        #expect(state(rig, job)?.notBefore == Date(timeIntervalSinceReferenceDate: 1010))

        rig.time.set(1010); rig.sleeper.releaseAll()
        #expect(await waitUntil { state(rig, job)?.attempts == 2 && rig.sleeper.pendingCount == 1 })
        #expect(state(rig, job)?.notBefore == Date(timeIntervalSinceReferenceDate: 1070))

        rig.time.set(1070); rig.sleeper.releaseAll()
        #expect(await waitUntil { state(rig, job)?.state == "failed" })
        let final = try #require(state(rig, job))
        #expect(final.attempts == 3 && final.failureReason == "timed out")
        #expect(runner.attemptLog.map(\.1) == [1, 2, 3])
        await rig.queue.stop()
    }

    @Test func aPermanentFailureFailsAtOnceWithoutUsingAnAttempt() async throws {
        let runner = FakeJobRunner(outcome: { _, _ in .permanent("picture no longer stored") })
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()
        #expect(await waitUntil { state(rig, job)?.state == "failed" })
        #expect(state(rig, job)?.attempts == 0)
        #expect(state(rig, job)?.failureReason == "picture no longer stored")
        #expect(runner.order.count == 1)
        await rig.queue.stop()
    }

    @Test func serverUnavailableReturnsTheJobToWaitingWithoutFailingAnything() async throws {
        let runner = FakeJobRunner(outcome: { _, _ in .serverUnavailable })
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()
        #expect(await waitUntil { rig.sleeper.pendingCount == 1 })
        let waiting = try #require(state(rig, job))
        #expect(waiting.state == "waiting" && waiting.attempts == 0 && waiting.notBefore == nil && waiting.failureReason == nil)
        #expect(try rig.store.counts().failed == 0)
        #expect(rig.sleeper.requested.last == .seconds(30))
        await rig.queue.stop()
    }

    // MARK: the gate

    @Test func aClosedGateHoldsTheQueueWithoutUsingAttemptsAndItResumesByItself() async throws {
        let gate = FakeGate(.notReachable)
        let rig = try makeRig(gate: gate); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()
        #expect(await waitUntil { rig.sleeper.pendingCount == 1 })
        #expect(await rig.queue.progress().holdingReason == "Ollama not reachable")
        #expect(rig.runner.order.isEmpty)
        #expect(state(rig, job)?.attempts == 0 && state(rig, job)?.state == "waiting")
        #expect(rig.sleeper.requested.last == .seconds(30))

        gate.set(.reachable(version: "0.34.4"))
        rig.sleeper.releaseAll()
        #expect(await waitUntil { state(rig, job)?.state == "finished" })
        #expect(await rig.queue.progress().holdingReason == nil)
        await rig.queue.stop()
    }

    @Test(arguments: [
        (ServerStatus.notReachable, "Ollama not reachable"),
        (ServerStatus.timedOut, "Ollama not reachable"),
        (ServerStatus.noVisionModel, "model not installed"),
        (ServerStatus.modelMissing("x"), "model not installed"),
        (ServerStatus.noModelChosen, "choose a model"),
    ])
    func theHoldingReasonFollowsTheServerStatus(status: ServerStatus, reason: String) {
        #expect(QueueProgress.holdingReason(for: status) == reason)
    }

    @Test func aReachableOrUncheckedStatusHasNoHoldingReason() {
        #expect(QueueProgress.holdingReason(for: .reachable(version: "1")) == nil)
        #expect(QueueProgress.holdingReason(for: .unchecked) == nil)
    }

    @Test func nudgeMakesAHeldQueueCheckTheGateAtOnce() async throws {
        let gate = FakeGate(.noModelChosen)
        let rig = try makeRig(gate: gate); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()
        #expect(await waitUntil { rig.sleeper.pendingCount == 1 })
        #expect(await rig.queue.progress().holdingReason == "choose a model")
        gate.set(.reachable(version: "0.34.4"))
        await rig.queue.nudge()
        #expect(await waitUntil { state(rig, job)?.state == "finished" })
        await rig.queue.stop()
    }

    // MARK: start, pause, retry, clear

    @Test func startPutsRunningJobsBackToWaitingWithAttemptsUnchanged() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        try rig.store.markWaiting(id: job.id, failedAttempts: 1, notBefore: nil, now: Date())
        try rig.store.markRunning(id: job.id, now: Date())
        #expect(state(rig, job)?.state == "running")
        await rig.queue.start()
        #expect(await waitUntil { state(rig, job)?.state == "finished" })
        #expect(rig.runner.attemptLog.first?.1 == 2)          // attempts 1 was kept, so this is the second try
        await rig.queue.stop()
    }

    @Test func pauseLetsTheRunningJobFinishAndStartsNothingNew() async throws {
        let latch = FakeLatch()
        let runner = FakeJobRunner(latch: latch)
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let first = try add(rig, createdAt: 1000)
        let second = try add(rig, createdAt: 1001)
        await rig.queue.start()
        #expect(await waitUntil { runner.activeNow == 1 })
        await rig.queue.pause(true)
        latch.open()
        #expect(await waitUntil { state(rig, first)?.state == "finished" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(state(rig, second)?.state == "waiting")
        #expect(runner.order == [first.id])
        #expect(rig.settings.analysisPaused)
        #expect(await rig.queue.progress().paused)

        await rig.queue.pause(false)
        #expect(await waitUntil { state(rig, second)?.state == "finished" })
        await rig.queue.stop()
    }

    @Test func aNewQueueStartsPausedWhenTheFlagWasStored() async throws {
        let settingsStore = FakeSettingsStore()
        OllamaSettings(store: settingsStore).setAnalysisPaused(true)
        let rig = try makeRig(settingsStore: settingsStore); defer { rig.temp.cleanUp() }
        let job = try add(rig, createdAt: 1000)
        await rig.queue.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await rig.queue.progress().paused)
        #expect(state(rig, job)?.state == "waiting" && rig.runner.order.isEmpty)
        await rig.queue.stop()
    }

    @Test func retryFailedAndClearFinishedFollowTheDataModel() async throws {
        let runner = FakeJobRunner(outcome: { _, _ in .permanent("nope") })
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let failing = try add(rig, createdAt: 1000)
        await rig.queue.start()
        #expect(await waitUntil { state(rig, failing)?.state == "failed" })

        runner.setOutcome { _, _ in .success }
        try await rig.queue.retryFailed()
        #expect(await waitUntil { state(rig, failing)?.state == "finished" })
        #expect(state(rig, failing)?.attempts == 0 && state(rig, failing)?.failureReason == nil)

        try await rig.queue.clearFinished()
        #expect(state(rig, failing) == nil)
        #expect(try rig.store.counts() == JobCounts(waiting: 0, running: 0, finished: 0, failed: 0))
        await rig.queue.stop()
    }

    // MARK: progress and enqueue

    @Test func progressUpdatesStartWithTheCurrentValueAndEachChangeOnce() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        var iterator = await rig.queue.progressUpdates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == QueueProgress(counts: JobCounts(waiting: 0, running: 0, finished: 0, failed: 0), paused: false, holdingReason: nil))
        await rig.queue.start()
        try await rig.queue.enqueueTest(imageID: nil)
        var seen: [QueueProgress] = [first!]
        while let next = await iterator.next() {
            seen.append(next)
            if next.counts.finished == 1 { break }
        }
        for (earlier, later) in zip(seen, seen.dropFirst()) { #expect(earlier != later) }
        #expect(seen.contains { $0.counts.waiting == 1 })
        #expect(seen.last?.counts.finished == 1)
        await rig.queue.stop()
    }

    @Test func enqueueTestCreatesAWaitingJobAndWakesTheLoop() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        await rig.queue.start()
        try await Task.sleep(for: .milliseconds(50))            // the loop is idle and waiting for a wake
        try await rig.queue.enqueueTest(imageID: "image-7")
        #expect(await waitUntil { (try? rig.store.counts().finished) == 1 })
        #expect(rig.runner.order.count == 1)
        let job = try #require(state(rig, AnalysisJobRecord(id: rig.runner.order[0], imageId: nil, createdAt: Date())))
        #expect(job.imageId == "image-7" && job.kind == "test")
        await rig.queue.stop()
    }

    // MARK: job kinds (spec 004)

    @Test func enqueueWithAKindCreatesAWaitingJobOfThatKindAndWakesTheLoop() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        await rig.queue.start()
        try await Task.sleep(for: .milliseconds(50))              // the loop is idle and waiting for a wake
        let id = try await rig.queue.enqueue(kind: "analyse", imageID: "image-9")
        #expect(await waitUntil { (try? rig.store.counts().finished) == 1 })
        let job = try #require(try rig.store.job(id: id))
        #expect(job.kind == "analyse" && job.imageId == "image-9")
        #expect(rig.runner.order == [id])
        await rig.queue.stop()
    }

    @Test func enqueueAnalysisCreatesOneAnalyseJobPerPictureInOrder() async throws {
        let runner = FakeJobRunner(latch: FakeLatch())             // closed: jobs stay waiting
        let rig = try makeRig(runner: runner); defer { rig.temp.cleanUp() }
        let enqueuer: any AnalysisEnqueuing = rig.queue
        await enqueuer.enqueueAnalysis(imageIDs: ["a", "b", "c"])
        #expect(try rig.store.counts().waiting == 3)
        let first = try #require(try rig.store.nextRunnable(now: Date(timeIntervalSinceReferenceDate: 1e9)))
        #expect(first.kind == "analyse" && first.imageId == "a")
    }

    // MARK: Backlog and reanalysis

    private func addPicture(_ rig: Rig, id: String, at seconds: TimeInterval) throws {
        let event = makeEventRecord(id: "e-\(id)", at: Date(timeIntervalSinceReferenceDate: seconds))
        try CaptureStore(database: rig.database).insert(event: event, images: [makeImageRecord(eventID: event.id, id: id)])
    }

    @Test func enqueueBacklogAddsOneJobPerUnanalysedPictureOldestFirstAndOnlyOnce() async throws {
        let rig = try makeRig(runner: FakeJobRunner(latch: FakeLatch())); defer { rig.temp.cleanUp() }
        try addPicture(rig, id: "new", at: 300)
        try addPicture(rig, id: "old", at: 100)
        try addPicture(rig, id: "mid", at: 200)
        let first = await rig.queue.enqueueBacklog()
        #expect(first == 3)
        let second = await rig.queue.enqueueBacklog()
        #expect(second == 0)
        #expect(try rig.store.counts().waiting == 3)
        let next = try #require(try rig.store.nextRunnable(now: Date(timeIntervalSinceReferenceDate: 1e9)))
        #expect(next.kind == "analyse" && next.imageId == "old")
    }

    @Test func aPictureWithAnAnalysisIsNotInTheBacklog() async throws {
        let rig = try makeRig(runner: FakeJobRunner(latch: FakeLatch())); defer { rig.temp.cleanUp() }
        try addPicture(rig, id: "done", at: 100)
        try await rig.database.pool.write {
            try $0.execute(sql: """
                INSERT INTO image_analysis (image_id, screen_kind, kind_confidence, classify_version, prompt_version, schema_version, model,
                    picture_long_edge, timezone, timezone_source, finding_count, analysed_at)
                VALUES ('done', 'other', 1, 'c', 'p', 's', 'm', 1, 'UTC', 'mac', 0, ?)
                """, arguments: [Date()])
        }
        let added = await rig.queue.enqueueBacklog()
        #expect(added == 0)
    }

    @Test func reanalyseAddsAForcedJobAndNeverQueuesAWaitingPictureTwice() async throws {
        let rig = try makeRig(runner: FakeJobRunner(latch: FakeLatch())); defer { rig.temp.cleanUp() }
        try addPicture(rig, id: "a", at: 100)
        let first = await rig.queue.reanalyse(imageID: "a")
        let second = await rig.queue.reanalyse(imageID: "a")
        #expect(first && !second)
        #expect(try rig.store.counts().waiting == 1)
        #expect(try rig.store.nextRunnable(now: Date(timeIntervalSinceReferenceDate: 1e9))?.kind == "analyse-force")
        let backlog = await rig.queue.enqueueBacklog()
        #expect(backlog == 0, "a picture with a waiting job is not in the backlog")
    }
}
