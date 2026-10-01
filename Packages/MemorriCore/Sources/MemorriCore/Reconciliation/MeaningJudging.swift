import Foundation

public enum MeaningJudgeError: Error, Equatable {
    /// No model chosen or installed for the call, or the server cannot be asked.
    case unavailable
    /// The answer held neither "yes" nor "no".
    case badAnswer
}

/// One sighting as the same-event judge reads it: the title, when it is and the context.
public struct JudgedSighting: Sendable, Equatable {
    public let title: String
    public let when: String
    public let context: String?

    public init(title: String, when: String, context: String?) { self.title = title; self.when = when; self.context = context }
}

/// What reconciliation asks of the local models: a vector for a title and a yes or no on two sightings. Both are optional
/// helpers; text and time decide without them.
public protocol MeaningJudging: Sendable {
    /// One vector per normalised title, in order.
    func embeddings(for titles: [String]) async throws -> [[Float]]
    /// The probability that two sightings are the same event.
    func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double
    var canEmbed: Bool { get async }
    var canJudge: Bool { get async }
}

/// Text and time only: used when no matching model is chosen.
public struct NoMeaningJudge: MeaningJudging {
    public init() {}
    public func embeddings(for titles: [String]) async throws -> [[Float]] { throw MeaningJudgeError.unavailable }
    public func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double { throw MeaningJudgeError.unavailable }
    public var canEmbed: Bool { false }
    public var canJudge: Bool { false }
}
