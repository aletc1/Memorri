import Foundation
import Testing
@testable import MemorriCore

@Suite struct ModelTestResultLineTests {
    private func job(_ state: AnalysisJobRecord.State, reason: String? = nil) -> AnalysisJobRecord {
        AnalysisJobRecord(imageId: nil, state: state, failureReason: reason, createdAt: Date())
    }

    private func run(_ answer: String?, ms: Int = 12_400) -> ModelRunRecord {
        ModelRunRecord(jobId: "j", imageId: nil, attempt: 1, model: "m", think: "off", temperature: 0, imageLongEdge: 2048,
                       promptVersion: "test-v1", schemaVersion: "test-v1", startedAt: Date(), durationMs: ms,
                       outcome: .success, failureReason: nil, requestJson: "{}", rawAnswer: answer)
    }

    @Test func aFinishedJobShowsTheTimeAndTheStartOfTheDescription() {
        let answer = #"{"description":"A weekly calendar with one event.","contains_text":true,"text_sample":"x"}"#
        #expect(ModelTestResultLine.text(job: job(.finished), run: run(answer)) == #"Answer valid in 12.4 s: "A weekly calendar with one event.""#)
    }

    @Test func aLongDescriptionIsCutAtSixtyCharacters() {
        let long = String(repeating: "a", count: 100)
        let answer = #"{"description":"\#(long)","contains_text":false,"text_sample":""}"#
        let text = ModelTestResultLine.text(job: job(.finished), run: run(answer)) ?? ""
        #expect(text.hasSuffix("\"" + String(repeating: "a", count: 60) + "…\""))
    }

    @Test func aFailedJobShowsItsReason() {
        #expect(ModelTestResultLine.text(job: job(.failed, reason: "invalid answer"), run: nil) == "Failed: invalid answer")
    }

    @Test func aJobThatIsStillWaitingOrRunningHasNoLine() {
        #expect(ModelTestResultLine.text(job: job(.waiting), run: nil) == nil)
        #expect(ModelTestResultLine.text(job: job(.running), run: nil) == nil)
    }
}
