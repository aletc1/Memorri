import Foundation
import Testing
@testable import MemorriCore

@Suite struct AnalysisStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Harness {
        let temp = TempDirectory()
        let context: StorageContext
        let store: AnalysisStore

        init() throws {
            context = try StorageBootstrap.start(paths: AppPaths(root: temp.url.appendingPathComponent("Memorri")))
            store = AnalysisStore(database: context.database!)
        }
    }

    private func job(_ id: String, at seconds: TimeInterval, image: String? = nil) -> AnalysisJobRecord {
        AnalysisJobRecord(id: id, imageId: image, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    private func run(_ id: String, job: String, image: String?, outcome: ModelRunRecord.Outcome = .success) -> ModelRunRecord {
        ModelRunRecord(id: id, jobId: job, imageId: image, attempt: 1, model: "m", think: "off", temperature: 0,
                       imageLongEdge: 2048, promptVersion: "test-v1", schemaVersion: "test-v1", startedAt: t0,
                       durationMs: 10, outcome: outcome, failureReason: nil, requestJson: "{}", rawAnswer: "{}")
    }

    @Test func theOldestWaitingJobComesFirst() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("late", at: 20))
        try h.store.enqueue(job("early", at: 5))
        try h.store.enqueue(job("middle", at: 10))
        #expect(try h.store.nextRunnable(now: t0.addingTimeInterval(100))?.id == "early")
    }

    @Test func aJobWithAFutureNotBeforeIsSkippedUntilItsTime() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("a", at: 1))
        try h.store.enqueue(job("b", at: 2))
        try h.store.markWaiting(id: "a", failedAttempts: 1, notBefore: t0.addingTimeInterval(60), now: t0)
        #expect(try h.store.nextRunnable(now: t0.addingTimeInterval(30))?.id == "b")
        #expect(try h.store.nextRunnable(now: t0.addingTimeInterval(60))?.id == "a")          // not_before reached
    }

    @Test func nextWakeUpIsTheEarliestFutureNotBefore() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        #expect(try h.store.nextWakeUp(now: t0) == nil)
        try h.store.enqueue(job("a", at: 1)); try h.store.enqueue(job("b", at: 2)); try h.store.enqueue(job("c", at: 3))
        try h.store.markWaiting(id: "a", failedAttempts: 1, notBefore: t0.addingTimeInterval(90), now: t0)
        try h.store.markWaiting(id: "b", failedAttempts: 1, notBefore: t0.addingTimeInterval(30), now: t0)
        #expect(try h.store.nextWakeUp(now: t0) == t0.addingTimeInterval(30))
        #expect(try h.store.nextWakeUp(now: t0.addingTimeInterval(40)) == t0.addingTimeInterval(90))   // past ones are ignored
        #expect(try h.store.nextWakeUp(now: t0.addingTimeInterval(100)) == nil)
    }

    @Test func transitionsChangeStateAttemptsAndReason() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("j", at: 1))
        try h.store.markRunning(id: "j", now: t0.addingTimeInterval(2))
        var record = try #require(try h.store.job(id: "j"))
        #expect(record.state == "running" && record.attempts == 0 && record.updatedAt == t0.addingTimeInterval(2))

        try h.store.markWaiting(id: "j", failedAttempts: 1, notBefore: t0.addingTimeInterval(70), now: t0.addingTimeInterval(3))
        record = try #require(try h.store.job(id: "j"))
        #expect(record.state == "waiting" && record.attempts == 1 && record.notBefore == t0.addingTimeInterval(70))

        try h.store.markFailed(id: "j", failedAttempts: 3, reason: "invalid answer", now: t0.addingTimeInterval(4))
        record = try #require(try h.store.job(id: "j"))
        #expect(record.state == "failed" && record.attempts == 3 && record.failureReason == "invalid answer")

        try h.store.enqueue(job("k", at: 5))
        try h.store.markFinished(id: "k", now: t0.addingTimeInterval(6))
        #expect(try h.store.job(id: "k")?.state == "finished")
    }

    @Test func markWaitingWithoutANotBeforeClearsIt() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("j", at: 1))
        try h.store.markWaiting(id: "j", failedAttempts: 1, notBefore: t0.addingTimeInterval(60), now: t0)
        try h.store.markWaiting(id: "j", failedAttempts: 1, notBefore: nil, now: t0)
        #expect(try h.store.job(id: "j")?.notBefore == nil)
    }

    @Test func recoverRunningJobsPutsThemBackWithAttemptsUnchanged() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("a", at: 1)); try h.store.enqueue(job("b", at: 2)); try h.store.enqueue(job("c", at: 3))
        try h.store.markWaiting(id: "a", failedAttempts: 2, notBefore: nil, now: t0)
        try h.store.markRunning(id: "a", now: t0)
        try h.store.markRunning(id: "b", now: t0)
        #expect(try h.store.recoverRunningJobs() == 2)
        #expect(try h.store.job(id: "a")?.state == "waiting" && h.store.job(id: "a")?.attempts == 2)
        #expect(try h.store.job(id: "b")?.state == "waiting" && h.store.job(id: "b")?.attempts == 0)
        #expect(try h.store.recoverRunningJobs() == 0)
    }

    @Test func countsAndRecentFailures() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        for (index, id) in ["w1", "w2", "r", "f1", "f2", "f3", "done"].enumerated() { try h.store.enqueue(job(id, at: Double(index))) }
        try h.store.markRunning(id: "r", now: t0)
        try h.store.markFailed(id: "f1", failedAttempts: 3, reason: "timed out", now: t0.addingTimeInterval(10))
        try h.store.markFailed(id: "f2", failedAttempts: 3, reason: "invalid answer", now: t0.addingTimeInterval(20))
        try h.store.markFailed(id: "f3", failedAttempts: 0, reason: "picture no longer stored", now: t0.addingTimeInterval(30))
        try h.store.markFinished(id: "done", now: t0)
        #expect(try h.store.counts() == JobCounts(waiting: 2, running: 1, finished: 1, failed: 3))
        #expect(try h.store.recentFailures(limit: 2).map(\.id) == ["f3", "f2"])
        #expect(try h.store.recentFailures(limit: 5).count == 3)
    }

    @Test func retryFailedResetsFailedJobsOnly() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        try h.store.enqueue(job("f", at: 1)); try h.store.enqueue(job("w", at: 2))
        try h.store.markFailed(id: "f", failedAttempts: 3, reason: "timed out", now: t0)
        #expect(try h.store.retryFailed(now: t0.addingTimeInterval(5)) == 1)
        let record = try #require(try h.store.job(id: "f"))
        #expect(record.state == "waiting" && record.attempts == 0 && record.notBefore == nil && record.failureReason == nil)
        #expect(try h.store.retryFailed(now: t0) == 0)
    }

    @Test func clearFinishedDeletesFinishedAndFailedJobsAndOnlyTheirImagelessRuns() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        try h.context.store!.insert(event: event, images: [image])
        for (index, id) in ["done", "failed", "waiting", "running"].enumerated() { try h.store.enqueue(job(id, at: Double(index), image: id == "waiting" ? nil : nil)) }
        try h.store.markFinished(id: "done", now: t0)
        try h.store.markFailed(id: "failed", failedAttempts: 3, reason: "x", now: t0)
        try h.store.markRunning(id: "running", now: t0)
        try h.store.record(run: run("sample-done", job: "done", image: nil))
        try h.store.record(run: run("sample-failed", job: "failed", image: nil, outcome: .failed))
        try h.store.record(run: run("capture-done", job: "done", image: image.id))
        try h.store.record(run: run("sample-waiting", job: "waiting", image: nil))
        #expect(try h.store.clearFinished() == 2)
        #expect(try h.store.job(id: "done") == nil && h.store.job(id: "failed") == nil)
        #expect(try h.store.job(id: "waiting") != nil && h.store.job(id: "running") != nil)
        #expect(try h.store.runs().map(\.id).sorted() == ["capture-done", "sample-waiting"])
    }

    @Test func aRecordedRunKeepsItsFields() throws {
        let h = try Harness(); defer { h.temp.cleanUp() }
        let saved = run("r1", job: "j", image: nil)
        try h.store.record(run: saved)
        #expect(try h.store.runs() == [saved])
    }

    @Test func theNewestSuccessfulRunOfAStepAndVersionIsFound() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisStore(database: fixture.database)
        try store.enqueue(job("j", at: 1, image: fixture.imageID))
        func record(_ id: String, step: String, version: String, outcome: ModelRunRecord.Outcome, at: TimeInterval) -> ModelRunRecord {
            ModelRunRecord(id: id, jobId: "j", imageId: fixture.imageID, attempt: 1, model: "m", think: "off", temperature: 0,
                           imageLongEdge: 1024, promptVersion: version, schemaVersion: "s", startedAt: t0.addingTimeInterval(at),
                           durationMs: 10, outcome: outcome, failureReason: nil, requestJson: "{}", rawAnswer: id, step: step)
        }
        try store.record(run: record("old", step: "classify", version: "classify-v1", outcome: .success, at: 1))
        try store.record(run: record("new", step: "classify", version: "classify-v1", outcome: .success, at: 5))
        try store.record(run: record("failed", step: "classify", version: "classify-v1", outcome: .failed, at: 9))
        try store.record(run: record("other-version", step: "classify", version: "classify-v2", outcome: .success, at: 10))
        try store.record(run: record("other-step", step: "extract", version: "classify-v1", outcome: .success, at: 11))
        #expect(try store.latestSuccessfulRun(imageID: fixture.imageID, step: "classify", promptVersion: "classify-v1")?.rawAnswer == "new")
        #expect(try store.latestSuccessfulRun(imageID: fixture.imageID, step: "classify", promptVersion: "classify-v2") == nil)
        #expect(try store.latestSuccessfulRun(imageID: "nobody", step: "classify", promptVersion: "classify-v1") == nil)
    }
}
