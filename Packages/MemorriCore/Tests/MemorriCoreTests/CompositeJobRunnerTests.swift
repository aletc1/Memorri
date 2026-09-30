import Foundation
import Testing
@testable import MemorriCore

@Suite struct CompositeJobRunnerTests {
    private func job(_ kind: String) -> AnalysisJobRecord {
        AnalysisJobRecord(kind: kind, imageId: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func aJobGoesToTheRunnerOfItsKind() async {
        let test = FakeJobRunner(outcome: { _, _ in .success })
        let analyse = FakeJobRunner(outcome: { _, _ in .transient("timed out") })
        let composite = CompositeJobRunner(runners: ["test": test, "analyse": analyse])
        let a = job("analyse"), t = job("test")
        #expect(await composite.run(a, attempt: 1) == .transient("timed out"))
        #expect(await composite.run(t, attempt: 1) == .success)
        #expect(analyse.order == [a.id] && test.order == [t.id])
    }

    @Test func theAttemptNumberIsPassedOn() async {
        let runner = FakeJobRunner()
        let composite = CompositeJobRunner(runners: ["analyse": runner])
        let item = job("analyse")
        _ = await composite.run(item, attempt: 3)
        #expect(runner.attemptLog.map(\.1) == [3])
    }

    @Test func anUnknownKindFailsAtOnce() async {
        let composite = CompositeJobRunner(runners: ["test": FakeJobRunner()])
        #expect(await composite.run(job("mystery"), attempt: 1) == .permanent("unknown job kind"))
    }

    @Test func oneRunnerCanServeSeveralKinds() async {
        let runner = FakeJobRunner()
        let composite = CompositeJobRunner(runners: ["analyse": runner, "analyse-force": runner])
        #expect(await composite.run(job("analyse-force"), attempt: 1) == .success)
        #expect(await composite.run(job("analyse"), attempt: 1) == .success)
        #expect(runner.order.count == 2)
    }
}
