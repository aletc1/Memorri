import Testing
@testable import MemorriCore

@Suite struct AnalysisLineTests {
    private func progress(waiting: Int = 0, running: Int = 0, finished: Int = 0, failed: Int = 0,
                          paused: Bool = false, reason: String? = nil) -> QueueProgress {
        QueueProgress(counts: JobCounts(waiting: waiting, running: running, finished: finished, failed: failed),
                      paused: paused, holdingReason: reason)
    }

    @Test func nothingQueuedIsIdle() {
        #expect(AnalysisLine.text(for: progress()) == "Analysis: idle")
        #expect(AnalysisLine.text(for: progress(finished: 7)) == "Analysis: idle")
    }

    @Test func waitingJobsAreCounted() {
        #expect(AnalysisLine.text(for: progress(waiting: 3)) == "Analysis: 3 waiting")
    }

    @Test func aRunningJobShowsItsPlaceInTheTotal() {
        #expect(AnalysisLine.text(for: progress(waiting: 3, running: 1)) == "Analysing 1 of 4…")
        #expect(AnalysisLine.text(for: progress(running: 1)) == "Analysing 1 of 1…")
    }

    @Test(arguments: ["Ollama not reachable", "model not installed", "choose a model"])
    func aHeldQueueSaysWhy(reason: String) {
        #expect(AnalysisLine.text(for: progress(waiting: 2, reason: reason)) == "Analysis waiting: \(reason)")
    }

    @Test func aReasonWithNothingWaitingIsNotShown() {
        #expect(AnalysisLine.text(for: progress(reason: "Ollama not reachable")) == "Analysis: idle")
    }

    @Test func pausedComesFirst() {
        #expect(AnalysisLine.text(for: progress(waiting: 2, paused: true)) == "Analysis paused")
        #expect(AnalysisLine.text(for: progress(waiting: 2, paused: true, reason: "choose a model")) == "Analysis paused")
        #expect(AnalysisLine.text(for: progress(waiting: 2, running: 1, paused: true)) == "Analysis paused")
    }

    @Test func holdingComesBeforeRunningAndWaiting() {
        #expect(AnalysisLine.text(for: progress(waiting: 1, running: 1, reason: "Ollama not reachable")) == "Analysis waiting: Ollama not reachable")
    }

    @Test func failuresAreAppended() {
        #expect(AnalysisLine.text(for: progress(waiting: 2, failed: 1)) == "Analysis: 2 waiting, 1 failed")
        #expect(AnalysisLine.text(for: progress(failed: 1)) == "Analysis: idle, 1 failed")
        #expect(AnalysisLine.text(for: progress(failed: 2, paused: true)) == "Analysis paused, 2 failed")
        #expect(AnalysisLine.text(for: progress(waiting: 1, running: 1, failed: 3)) == "Analysing 1 of 2…, 3 failed")
        #expect(AnalysisLine.text(for: progress(waiting: 1, failed: 1, reason: "choose a model")) == "Analysis waiting: choose a model, 1 failed")
    }
}
