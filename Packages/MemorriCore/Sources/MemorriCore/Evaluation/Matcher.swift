import Foundation

/// A finding as the eval compares it: what the pipeline produced for a golden case.
public struct FoundFinding: Sendable, Equatable, Codable {
    public let kind: String
    public let title: String
    public let start: Date?
    public let end: Date?
    public let due: Date?
    public let remind: Date?
    public let allDay: Bool
    public let people: [String]
    public let place: String?
    /// Fields the pipeline flagged as inferred.
    public let inferred: [String]
    public let confidence: Double
    public let citedLines: [Int]
    /// The text of the cited lines, joined, for the title-versus-citation check.
    public let citedText: String?
    /// The window it was read from, when the picture was read window by window.
    public let windowKey: String?

    public init(kind: String, title: String, start: Date? = nil, end: Date? = nil, due: Date? = nil, remind: Date? = nil,
                allDay: Bool = false, people: [String] = [], place: String? = nil, inferred: [String] = [],
                confidence: Double = 1, citedLines: [Int] = [], citedText: String? = nil, windowKey: String? = nil) {
        self.windowKey = windowKey
        self.kind = kind; self.title = title; self.start = start; self.end = end; self.due = due; self.remind = remind
        self.allDay = allDay; self.people = people; self.place = place; self.inferred = inferred
        self.confidence = confidence; self.citedLines = citedLines; self.citedText = citedText
    }
}

public struct MatchThresholds: Sendable, Equatable, Codable {
    public let titleSimilarity: Double
    public let minutes: Double
    /// Titles shorter than this (after normalising) never count as contained in another title.
    public let minimumContainedLength: Int

    public static let standard = MatchThresholds(titleSimilarity: 0.80, minutes: 5, minimumContainedLength: 3)
}

public struct MatchPair: Sendable, Equatable {
    public let expectedIndex: Int
    public let foundIndex: Int
    public let similarity: Double
}

public struct MatchResult: Sendable, Equatable {
    public let pairs: [MatchPair]
    public let unmatchedExpected: [Int]
    public let unmatchedFound: [Int]
}

/// One-to-one matching of found findings to expected ones (research R17): same kind, titles at least 80%
/// similar (or one inside the other) and the start (or due date for tasks and deadlines) within 5 minutes.
public enum Matcher {
    /// All-day items match on the date: half a day either way.
    static let allDaySeconds: TimeInterval = 12 * 3600

    public static func match(expected: [ExpectedFinding], found: [FoundFinding],
                             thresholds: MatchThresholds = .standard) -> MatchResult {
        struct Candidate { let e: Int; let f: Int; let similarity: Double; let gap: TimeInterval }
        var candidates: [Candidate] = []
        for (e, want) in expected.enumerated() {
            for (f, got) in found.enumerated() where want.kind == got.kind {
                let similarity = titleSimilarity(want.title, got.title, thresholds: thresholds)
                guard similarity >= thresholds.titleSimilarity else { continue }
                guard let gap = timeGap(want, got, thresholds: thresholds) else { continue }
                candidates.append(Candidate(e: e, f: f, similarity: similarity, gap: gap))
            }
        }
        candidates.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            return ($0.e, $0.f) < ($1.e, $1.f)
        }
        var usedExpected = Set<Int>(), usedFound = Set<Int>(), pairs: [MatchPair] = []
        for c in candidates where !usedExpected.contains(c.e) && !usedFound.contains(c.f) {
            usedExpected.insert(c.e); usedFound.insert(c.f)
            pairs.append(MatchPair(expectedIndex: c.e, foundIndex: c.f, similarity: c.similarity))
        }
        pairs.sort { $0.expectedIndex < $1.expectedIndex }
        return MatchResult(pairs: pairs,
                           unmatchedExpected: expected.indices.filter { !usedExpected.contains($0) },
                           unmatchedFound: found.indices.filter { !usedFound.contains($0) })
    }

    /// Nil when the times disagree; 0 when there is no time to compare.
    private static func timeGap(_ want: ExpectedFinding, _ got: FoundFinding, thresholds: MatchThresholds) -> TimeInterval? {
        let pair: (Date, Date?)?
        if let start = want.start { pair = (start, got.start) }
        else if let due = want.due { pair = (due, got.due) }
        else { pair = nil }
        guard let (wanted, actual) = pair else { return 0 }
        guard let actual else { return nil }
        let gap = abs(actual.timeIntervalSince(wanted))
        let limit = (want.allDay == true || got.allDay) ? allDaySeconds : thresholds.minutes * 60
        return gap <= limit ? gap : nil
    }

    // MARK: Titles

    /// Lowercase letters and digits only: case, spaces and punctuation do not matter.
    public static func normalise(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 for equal titles; a title inside the other scores 0.8 to 1 by how much of it is covered; otherwise
    /// one minus the edit distance over the longer length.
    public static func titleSimilarity(_ a: String, _ b: String, thresholds: MatchThresholds = .standard) -> Double {
        let x = normalise(a), y = normalise(b)
        if x == y { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        let longer = max(x.count, y.count), shorter = min(x.count, y.count)
        var score = 1 - Double(editDistance(Array(x), Array(y))) / Double(longer)
        if shorter >= thresholds.minimumContainedLength, x.contains(y) || y.contains(x) {
            score = max(score, 0.8 + 0.2 * Double(shorter) / Double(longer) * 0.99)
        }
        return score
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
