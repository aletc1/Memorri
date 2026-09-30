import Foundation

/// Picks the context a picture belongs to from what it shows: the window titles and applications captured with it, the
/// environment tags, and the recognised text (research R10). Transparent and without learning: each hint that matches adds
/// points, and the winner needs both enough points and a clear lead.
public enum ContextMatcher {
    /// A context needs at least this many points ...
    public static let minimumScore = 2.0
    /// ... and at least this many more than the next one.
    public static let minimumLead = 1.0

    public static func points(for kind: ContextHint.Kind) -> Double {
        switch kind {
        case .windowTitle, .app: 3
        case .domain: 2.5
        case .keyword: 1
        }
    }

    public static func decide(contexts: [ContextRecord], windows: [WindowInfo], tags: [CaptureTag], lines: [RecognisedLine]) -> ContextDecision {
        func tagValues(_ keys: Set<String>) -> [String] { tags.filter { keys.contains($0.key) }.map(\.value) }
        let lineTexts = lines.map(\.text)
        func sources(for kind: ContextHint.Kind) -> [String] {
            switch kind {
            case .windowTitle: windows.compactMap(\.title) + tagValues(["window_title_keywords"])
            case .app: windows.compactMap(\.appName) + windows.compactMap(\.bundleID) + tagValues(["window_app", "application", "remote_client", "remote_session"])
            case .domain: tagValues(["domain", "account"]) + lineTexts
            case .keyword: tagValues(["window_title_keywords"]) + lineTexts
            }
        }
        var cache: [ContextHint.Kind: [String]] = [:]
        func matches(_ hint: ContextHint) -> Bool {
            let texts = cache[hint.kind] ?? sources(for: hint.kind)
            cache[hint.kind] = texts
            return texts.contains { $0.range(of: hint.value, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        struct Scored { let context: ContextRecord; let score: Double; let matched: [MatchedHint] }
        let scored = contexts.map { context -> Scored in
            var seen = Set<String>()
            var matched: [MatchedHint] = []
            for hint in context.hints where seen.insert("\(hint.kind.rawValue)|\(hint.value.lowercased())").inserted && matches(hint) {
                matched.append(MatchedHint(hintKind: hint.kind.rawValue, value: hint.value, points: points(for: hint.kind)))
            }
            return Scored(context: context, score: matched.reduce(0) { $0 + $1.points }, matched: matched)
        }.sorted { ($0.score, $1.context.name) > ($1.score, $0.context.name) }

        guard let best = scored.first, best.score > 0 else { return .unassigned }
        let second = scored.count > 1 && scored[1].score > 0 ? scored[1] : nil
        if best.score >= minimumScore, best.score - (second?.score ?? 0) >= minimumLead {
            return ContextDecision(contextID: best.context.id, source: .auto, score: best.score, matched: best.matched,
                                   runnerUp: second.map { RunnerUp(contextId: $0.context.id, score: $0.score) })
        }
        if let second, second.score == best.score {
            let tied = scored.filter { $0.score == best.score }.map(\.context.id)
            return ContextDecision(contextID: nil, source: .none, score: 0, runnerUp: RunnerUp(tie: true, contextIds: tied))
        }
        // Not enough to go on: the closest candidate is kept so the picture's settings can show why it stayed unassigned.
        let candidate = best.score >= minimumScore ? second : best
        return ContextDecision(contextID: nil, source: .none, score: 0, runnerUp: candidate.map { RunnerUp(contextId: $0.context.id, score: $0.score) })
    }
}
