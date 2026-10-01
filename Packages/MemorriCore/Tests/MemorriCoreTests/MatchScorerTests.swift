import Foundation
import Testing
@testable import MemorriCore

@Suite struct MatchScorerTests {
    private let t = ReconcileThresholds.default

    private func decide(text: Double, time: Double, cosine: Double? = nil, undated: Bool = false) -> MatchDecision {
        MatchScorer.decide(MatchScores(text: text, time: time, cosine: cosine, rerank: nil), undated: undated, thresholds: t)
    }

    @Test func defaultThresholdsAreTheResearchStartValues() {
        #expect(t.mergeText == 0.9 && t.minTime == 0.5 && t.newText == 0.5 && t.newCosine == 0.88)
        #expect(t.rerankYes == 0.95 && t.undatedMergeText == 0.9 && t.undatedRerankText == 0.7)
    }

    @Test func aStrongTitleAndAgreeingTimesMerge() {
        #expect(decide(text: 0.95, time: 0.6) == .merge(rule: "text-time"))
        #expect(decide(text: 0.9, time: 0.5) == .merge(rule: "text-time"))
        #expect(decide(text: 1, time: 1) == .merge(rule: "text-time"))
    }

    @Test func aStrongTitleWithWeakTimeIsNotAutomaticallyMerged() {
        #expect(decide(text: 0.95, time: 0.4) != .merge(rule: "text-time"))
    }

    @Test func samePlaceInTimeWithAWeakTitleIsJudgedNotDropped() {
        // A translation: low text, same time. With or without a cosine it must reach the judge.
        #expect(decide(text: 0.2, time: 1) == .uncertain)
        #expect(decide(text: 0.2, time: 0.8, cosine: 0.856) == .uncertain)
        #expect(decide(text: 0.6, time: 0.8) == .uncertain)
    }

    @Test func aWeakTitleAndDifferentTimesIsANewItem() {
        #expect(decide(text: 0.2, time: 0.6) == .new(rule: "different"))
        #expect(decide(text: 0.49, time: 0.6, cosine: 0.8) == .new(rule: "different"))
        #expect(decide(text: 0.2, time: 0.5, cosine: nil) == .new(rule: "different"))
    }

    @Test func aHighCosineSendsAWeakTitleToTheJudge() {
        #expect(decide(text: 0.2, time: 0.6, cosine: 0.9) == .uncertain)
        #expect(decide(text: 0.2, time: 0.6, cosine: 0.88) == .uncertain)
    }

    @Test func aMiddlingTitleWithModestTimeIsUncertain() {
        #expect(decide(text: 0.7, time: 0.6) == .uncertain)
        #expect(decide(text: 0.5, time: 0.6) == .uncertain)
    }

    @Test func undatedItemsMergeOnlyOnAStrongTitle() {
        #expect(decide(text: 0.9, time: 1, undated: true) == .merge(rule: "undated-text"))
        #expect(decide(text: 0.8, time: 1, undated: true) == .uncertain)
        #expect(decide(text: 0.7, time: 1, undated: true) == .uncertain)
    }

    @Test func undatedItemsWithAWeakTitleAreNeverJudged() {
        #expect(decide(text: 0.69, time: 1, undated: true) == .new(rule: "undated-low-text"))
        #expect(decide(text: 0.1, time: 1, cosine: 0.99, undated: true) == .new(rule: "undated-low-text"))
    }

    @Test func afterTheJudgeAYesMergesANoSeparatesAndNothingSeparatesWithTheRule() {
        func after(_ p: Double?) -> MatchDecision {
            MatchScorer.decideAfterRerank(MatchScores(text: 0.3, time: 1, cosine: nil, rerank: p), thresholds: t)
        }
        #expect(after(0.99) == .merge(rule: "rerank-yes"))
        #expect(after(0.95) == .merge(rule: "rerank-yes"))
        #expect(after(0.9) == .new(rule: "rerank-no"))
        #expect(after(nil) == .new(rule: "judge-unavailable"))
    }

    @Test func scoresEncodeForTheStoredDecision() throws {
        let scores = MatchScores(text: 0.9, time: 1, cosine: nil, rerank: 0.7)
        let data = try JSONEncoder().encode(scores)
        #expect(try JSONDecoder().decode(MatchScores.self, from: data) == scores)
    }
}
