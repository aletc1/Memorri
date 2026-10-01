import Foundation

/// The numbers behind one comparison of a finding with a candidate item. Stored with the sighting (FR-019).
public struct MatchScores: Sendable, Equatable, Codable {
    public var text: Double
    public var time: Double
    /// Cosine of the two titles' embeddings; nil when unknown.
    public var cosine: Double?
    /// Probability of "same event" from the judge; nil when not asked or unavailable.
    public var rerank: Double?

    public init(text: Double, time: Double, cosine: Double? = nil, rerank: Double? = nil) {
        self.text = text; self.time = time; self.cosine = cosine; self.rerank = rerank
    }
}

public enum MatchDecision: Sendable, Equatable {
    case merge(rule: String)
    case new(rule: String)
    /// Needs the judge.
    case uncertain
}

/// The thresholds of research R7. Start values; the final ones come from `memorri-eval reconcile` and are written into ADR 0020.
public struct ReconcileThresholds: Sendable, Equatable, Codable {
    public var mergeText = 0.9
    public var minTime = 0.5
    public var sameTime = 0.8
    public var newText = 0.5
    public var newCosine = 0.88
    public var rerankYes = 0.95
    public var undatedMergeText = 0.9
    public var undatedRerankText = 0.7

    public static let `default` = ReconcileThresholds()
    public init() {}
}

public enum MatchScorer {
    /// The decision before the judge (research R7, rules 2 to 5).
    public static func decide(_ scores: MatchScores, undated: Bool, thresholds t: ReconcileThresholds) -> MatchDecision {
        if undated {
            if scores.text >= t.undatedMergeText { return .merge(rule: "undated-text") }
            if scores.text < t.undatedRerankText { return .new(rule: "undated-low-text") }
            return .uncertain
        }
        if scores.text >= t.mergeText && scores.time >= t.minTime { return .merge(rule: "text-time") }
        // The same moment with another title may be the same event in another language: that is for the judge.
        if scores.time >= t.sameTime { return .uncertain }
        if scores.text < t.newText, scores.cosine.map({ $0 < t.newCosine }) ?? true { return .new(rule: "different") }
        return .uncertain
    }

    public static func decideAfterRerank(_ scores: MatchScores, thresholds t: ReconcileThresholds) -> MatchDecision {
        guard let p = scores.rerank else { return .new(rule: "judge-unavailable") }
        return p >= t.rerankYes ? .merge(rule: "rerank-yes") : .new(rule: "rerank-no")
    }
}
