import Foundation

public struct FoundTag: Sendable, Equatable, Codable {
    public let key: String
    public let value: String
    public let confidence: Double
    public init(key: String, value: String, confidence: Double) { self.key = key; self.value = value; self.confidence = confidence }
}

public struct FoundLine: Sendable, Equatable, Codable {
    public let text: String
    /// x, y, width, height in the picture's pixels.
    public let box: [Int]
    public init(text: String, box: [Int]) { self.text = text; self.box = box }
}

public struct EvalStepRecord: Sendable, Equatable, Codable {
    public let step: String
    public let request: String
    public let rawAnswer: String?
    public let durationMs: Int
    public init(step: String, request: String, rawAnswer: String?, durationMs: Int) {
        self.step = step; self.request = request; self.rawAnswer = rawAnswer; self.durationMs = durationMs
    }
}

/// What the analysis produced for one golden case, in the form the scores compare.
public struct CaseResult: Sendable, Equatable, Codable {
    public let kind: String
    public let findings: [FoundFinding]
    public let tags: [FoundTag]
    public let contextName: String?
    public let lines: [FoundLine]
    public let seconds: Double
    public let steps: [EvalStepRecord]

    public init(kind: String, findings: [FoundFinding], tags: [FoundTag], contextName: String?, lines: [FoundLine],
                seconds: Double, steps: [EvalStepRecord]) {
        self.kind = kind; self.findings = findings; self.tags = tags; self.contextName = contextName
        self.lines = lines; self.seconds = seconds; self.steps = steps
    }
}

public struct TagScore: Sendable, Equatable, Codable {
    public var correct: Int
    public var wrong: Int
    public var missing: Int
    public init(correct: Int = 0, wrong: Int = 0, missing: Int = 0) { self.correct = correct; self.wrong = wrong; self.missing = missing }
    public var accuracy: Double? { correct + wrong + missing == 0 ? nil : Double(correct) / Double(correct + wrong + missing) }
}

public struct ConfidenceBandScore: Sendable, Equatable, Codable {
    public var found: Int
    public var matched: Int
    public init(found: Int = 0, matched: Int = 0) { self.found = found; self.matched = matched }
    public var precision: Double? { found == 0 ? nil : Double(matched) / Double(found) }
}

public struct UnexpectedFinding: Sendable, Equatable, Codable {
    public let found: FoundFinding
    public let closestExpectedTitle: String?
}

public struct CaseScore: Sendable, Equatable, Codable {
    public let foundCount: Int
    public let expectedCount: Int
    public let matchedCount: Int
    public let comparedFields: Int
    public let equalFields: Int
    public let kindCorrect: Bool
    public let contextCorrect: Bool?
    public let tagResults: [String: TagScore]
    public let wrongHighConfidenceTags: Int
    public let ocrExact: Int
    public let ocrExpected: Int
    public let ocrOverlap: Int
    public let ocrBoxed: Int
    public let missed: [ExpectedFinding]
    public let unexpected: [UnexpectedFinding]
    public let disagreements: [FoundFinding]
    public let foundDetails: [FoundDetail]
    public let seconds: Double
    /// Each wrong or missing tag in words (`theme: expected dark, found light (0.93)`), for reading what went wrong.
    public var tagProblems: [String]? = nil

    public struct FoundDetail: Sendable, Equatable, Codable { public let confidence: Double; public let matched: Bool }

    public var precision: Double { Metrics.ratio(matchedCount, foundCount) }
    public var recall: Double { Metrics.ratio(matchedCount, expectedCount) }
    public var fieldAccuracy: Double? { comparedFields == 0 ? nil : Double(equalFields) / Double(comparedFields) }
}

public struct Aggregate: Sendable, Equatable, Codable {
    public var cases = 0
    public var found = 0
    public var expected = 0
    public var matched = 0
    public var comparedFields = 0
    public var equalFields = 0
    public var kindCorrect = 0
    public var seconds = 0.0
    public var ocrExact = 0, ocrExpected = 0, ocrOverlap = 0, ocrBoxed = 0

    public var precision: Double { Metrics.ratio(matched, found) }
    public var recall: Double { Metrics.ratio(matched, expected) }
    public var fieldAccuracy: Double? { comparedFields == 0 ? nil : Double(equalFields) / Double(comparedFields) }
    public var classificationAccuracy: Double { cases == 0 ? 1 : Double(kindCorrect) / Double(cases) }
    public var meanSeconds: Double { cases == 0 ? 0 : seconds / Double(cases) }
    public var ocrExactRate: Double? { ocrExpected == 0 ? nil : Double(ocrExact) / Double(ocrExpected) }
    public var ocrOverlapRate: Double? { ocrBoxed == 0 ? nil : Double(ocrOverlap) / Double(ocrBoxed) }

    mutating func add(_ s: CaseScore) {
        cases += 1; found += s.foundCount; expected += s.expectedCount; matched += s.matchedCount
        comparedFields += s.comparedFields; equalFields += s.equalFields; kindCorrect += s.kindCorrect ? 1 : 0
        seconds += s.seconds
        ocrExact += s.ocrExact; ocrExpected += s.ocrExpected; ocrOverlap += s.ocrOverlap; ocrBoxed += s.ocrBoxed
    }
}

public struct Summary: Sendable, Equatable, Codable {
    public let overall: Aggregate
    public let byKind: [String: Aggregate]
    public let byOrigin: [String: Aggregate]
    public let byConfidence: [String: ConfidenceBandScore]
    public let tagAccuracy: [String: TagScore]
    public let contextAccuracy: Double?
    public let wrongHighConfidenceTags: Int
}

/// Precision, recall and field accuracy over matched findings, plus classification, tag, context and reading
/// scores (research R17).
public enum Metrics {
    /// A wrong tag with at least this confidence counts as wrong with high confidence (SC-012).
    public static let highConfidence = 0.6

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double { denominator == 0 ? 1 : Double(numerator) / Double(denominator) }

    public static func band(forConfidence value: Double) -> String { value < 0.6 ? "low" : (value <= 0.85 ? "mid" : "high") }

    public static func score(_ golden: GoldenCase, _ result: CaseResult, thresholds: MatchThresholds = .standard) -> CaseScore {
        let expected = golden.expected.findings
        let match = Matcher.match(expected: expected, found: result.findings, thresholds: thresholds)

        var compared = 0, equal = 0
        for pair in match.pairs {
            let (c, e) = compareFields(expected[pair.expectedIndex], result.findings[pair.foundIndex])
            compared += c; equal += e
        }

        let matchedFound = Set(match.pairs.map(\.foundIndex))
        let unexpected = match.unmatchedFound.map { index -> UnexpectedFinding in
            let found = result.findings[index]
            let closest = expected.max { Matcher.titleSimilarity($0.title, found.title) < Matcher.titleSimilarity($1.title, found.title) }
            return UnexpectedFinding(found: found, closestExpectedTitle: closest?.title)
        }

        let (tagResults, wrongHigh) = scoreTags(golden.expected.tags ?? [], result.tags)
        let tagProblems = describeTagProblems(golden.expected.tags ?? [], result.tags)
        let contextCorrect = golden.expected.context.map { $0.lowercased() == (result.contextName ?? "").lowercased() }
        let ocr = scoreLines(golden.expected.lines ?? [], result.lines)

        let disagreements = result.findings.filter { finding in
            guard let cited = finding.citedText, !cited.isEmpty else { return false }
            let title = Matcher.normalise(finding.title), text = Matcher.normalise(cited)
            return !title.isEmpty && !text.contains(title) && !title.contains(text)
        }
        let details = result.findings.indices.map { CaseScore.FoundDetail(confidence: result.findings[$0].confidence, matched: matchedFound.contains($0)) }

        return CaseScore(foundCount: result.findings.count, expectedCount: expected.count, matchedCount: match.pairs.count,
                         comparedFields: compared, equalFields: equal, kindCorrect: result.kind == golden.expected.screenKind,
                         contextCorrect: contextCorrect, tagResults: tagResults, wrongHighConfidenceTags: wrongHigh,
                         ocrExact: ocr.exact, ocrExpected: ocr.expected, ocrOverlap: ocr.overlap, ocrBoxed: ocr.boxed,
                         missed: match.unmatchedExpected.map { expected[$0] }, unexpected: unexpected,
                         disagreements: disagreements, foundDetails: details, seconds: result.seconds, tagProblems: tagProblems.isEmpty ? nil : tagProblems)
    }

    public static func summarise(_ scores: [(GoldenCase, CaseScore)]) -> Summary {
        var overall = Aggregate(), byKind: [String: Aggregate] = [:], byOrigin: [String: Aggregate] = [:]
        var bands: [String: ConfidenceBandScore] = [:], tags: [String: TagScore] = [:]
        var contextTotal = 0, contextRight = 0, wrongHigh = 0
        for (golden, score) in scores {
            overall.add(score)
            byKind[golden.expected.screenKind, default: Aggregate()].add(score)
            byOrigin[golden.origin.rawValue, default: Aggregate()].add(score)
            for detail in score.foundDetails {
                let key = band(forConfidence: detail.confidence)
                bands[key, default: ConfidenceBandScore()].found += 1
                if detail.matched { bands[key, default: ConfidenceBandScore()].matched += 1 }
            }
            for (key, value) in score.tagResults {
                tags[key, default: TagScore()].correct += value.correct
                tags[key, default: TagScore()].wrong += value.wrong
                tags[key, default: TagScore()].missing += value.missing
            }
            if let right = score.contextCorrect { contextTotal += 1; if right { contextRight += 1 } }
            wrongHigh += score.wrongHighConfidenceTags
        }
        return Summary(overall: overall, byKind: byKind, byOrigin: byOrigin, byConfidence: bands, tagAccuracy: tags,
                       contextAccuracy: contextTotal == 0 ? nil : Double(contextRight) / Double(contextTotal),
                       wrongHighConfidenceTags: wrongHigh)
    }

    // MARK: Pieces

    /// Compared fields: a date field when either side has it (its value and its inferred flag), all-day when
    /// either side says so, people and place when either side has them.
    private static func compareFields(_ want: ExpectedFinding, _ got: FoundFinding) -> (compared: Int, equal: Int) {
        var compared = 0, equal = 0
        func note(_ same: Bool) { compared += 1; if same { equal += 1 } }
        let wantInferred = Set(want.inferred ?? []), gotInferred = Set(got.inferred)
        for (name, w, g) in [("start", want.start, got.start), ("end", want.end, got.end), ("due", want.due, got.due), ("remind", want.remind, got.remind)] where w != nil || g != nil {
            note(w != nil && g != nil && abs(w!.timeIntervalSince(g!)) < 1)
            note(wantInferred.contains(name) == gotInferred.contains(name))
        }
        if want.allDay != nil || got.allDay { note((want.allDay ?? false) == got.allDay) }
        let wantPeople = Set((want.people ?? []).map { $0.lowercased() }), gotPeople = Set(got.people.map { $0.lowercased() })
        if !wantPeople.isEmpty || !gotPeople.isEmpty { note(wantPeople == gotPeople) }
        let wantPlace = Matcher.normalise(want.place ?? ""), gotPlace = Matcher.normalise(got.place ?? "")
        if !wantPlace.isEmpty || !gotPlace.isEmpty { note(wantPlace == gotPlace) }
        return (compared, equal)
    }

    /// Names of applications and sessions vary in how much they say (`Teams`, `Microsoft Teams`): one containing the other is the
    /// same. Every other tag must be equal.
    static func sameTag(_ key: String, _ a: String, _ b: String) -> Bool {
        let x = a.lowercased().trimmingCharacters(in: .whitespaces), y = b.lowercased().trimmingCharacters(in: .whitespaces)
        if x == y { return true }
        guard ["application", "remote_session", "calendar_name"].contains(key), !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    private static func scoreTags(_ expected: [ExpectedTag], _ found: [FoundTag]) -> ([String: TagScore], Int) {
        var results: [String: TagScore] = [:], wrongHigh = 0
        for tag in expected {
            let same = found.filter { $0.key == tag.key }
            if same.isEmpty { results[tag.key, default: TagScore()].missing += 1 }
            else if same.contains(where: { sameTag(tag.key, $0.value, tag.value) }) { results[tag.key, default: TagScore()].correct += 1 }
            else {
                results[tag.key, default: TagScore()].wrong += 1
                if same.contains(where: { $0.confidence >= highConfidence }) { wrongHigh += 1 }
            }
        }
        return (results, wrongHigh)
    }

    private static func describeTagProblems(_ expected: [ExpectedTag], _ found: [FoundTag]) -> [String] {
        expected.compactMap { tag in
            let same = found.filter { $0.key == tag.key }
            if same.isEmpty { return "\(tag.key): expected \(tag.value), none found" }
            if same.contains(where: { sameTag(tag.key, $0.value, tag.value) }) { return nil }
            return "\(tag.key): expected \(tag.value), found " + same.map { "\($0.value) (\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", ")
        }
    }

    private static func scoreLines(_ expected: [ExpectedLine], _ found: [FoundLine]) -> (exact: Int, expected: Int, overlap: Int, boxed: Int) {
        var exact = 0, overlap = 0, boxed = 0
        for line in expected {
            let matches = found.filter { readable($0.text) == readable(line.text) }
            if !matches.isEmpty { exact += 1 }
            if let box = line.box, box.count == 4 {
                boxed += 1
                if matches.contains(where: { overlaps($0.box, box) }) { overlap += 1 }
            }
        }
        return (exact, expected.count, overlap, boxed)
    }

    /// Reading is exact up to surrounding spaces and the kind of dash: the recogniser writes every dash as a hyphen.
    static func readable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
    }

    /// The boxes overlap by at least half of the smaller one.
    static func overlaps(_ a: [Int], _ b: [Int]) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        let ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])), iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
        let smaller = min(a[2] * a[3], b[2] * b[3])
        return smaller > 0 && Double(ix * iy) >= 0.5 * Double(smaller)
    }
}
