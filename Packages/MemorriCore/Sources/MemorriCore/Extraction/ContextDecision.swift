import Foundation

public struct MatchedHint: Sendable, Equatable, Codable {
    public let hintKind: String
    public let value: String
    public let points: Double

    public init(hintKind: String, value: String, points: Double) {
        self.hintKind = hintKind; self.value = value; self.points = points
    }
}

/// The other context that came closest, or the contexts that tied.
public struct RunnerUp: Sendable, Equatable, Codable {
    public var contextId: String?
    public var score: Double?
    public var tie: Bool?
    public var contextIds: [String]?

    public init(contextId: String? = nil, score: Double? = nil, tie: Bool? = nil, contextIds: [String]? = nil) {
        self.contextId = contextId; self.score = score; self.tie = tie; self.contextIds = contextIds
    }
}

/// Which context a picture belongs to, and why (a user choice is never replaced by analysis).
public struct ContextDecision: Sendable, Equatable {
    public enum Source: String, Sendable, Codable { case auto, user, none }

    public let contextID: String?
    public let source: Source
    public let score: Double
    public let matched: [MatchedHint]
    public let runnerUp: RunnerUp?

    public init(contextID: String?, source: Source, score: Double, matched: [MatchedHint] = [], runnerUp: RunnerUp? = nil) {
        self.contextID = contextID; self.source = source; self.score = score; self.matched = matched; self.runnerUp = runnerUp
    }

    public static let unassigned = ContextDecision(contextID: nil, source: .none, score: 0)
}
