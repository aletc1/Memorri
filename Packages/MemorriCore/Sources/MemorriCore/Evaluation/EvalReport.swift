import Foundation

public struct EvalSettings: Sendable, Equatable, Codable {
    public let model: String
    public let size: Int
    public let think: String
    public let promptVersions: [String: String]
    public let thresholds: MatchThresholds

    public init(model: String, size: Int, think: String, promptVersions: [String: String], thresholds: MatchThresholds) {
        self.model = model; self.size = size; self.think = think; self.promptVersions = promptVersions; self.thresholds = thresholds
    }
}

public struct OverallNumbers: Sendable, Equatable, Codable {
    public let cases: Int
    public let precision: Double
    public let recall: Double
    public let fieldAccuracy: Double?
    public let classificationAccuracy: Double
    public let meanSeconds: Double
    public let ocrExactRate: Double?
    public let ocrOverlapRate: Double?
    public let contextAccuracy: Double?
    public let wrongHighConfidenceTags: Int
}

public struct MissedFinding: Sendable, Equatable, Codable {
    public let expected: ExpectedFinding
    public let nearestFoundTitle: String?
}

public struct CaseReport: Sendable, Equatable, Codable {
    public let name: String
    public let origin: String
    public let expectedKind: String
    public let foundKind: String
    public let score: CaseScore
    public let missed: [MissedFinding]
    public let steps: [EvalStepRecord]

    public var precision: Double { score.precision }
    public var recall: Double { score.recall }
    public var fieldAccuracy: Double? { score.fieldAccuracy }
}

public enum EvalReportError: Error, Sendable, Equatable, CustomStringConvertible {
    case localCasesInTrackedFolder(String)
    public var description: String {
        switch self {
        case .localCasesInTrackedFolder(let path): "refusing to write a report with local cases under a tracked folder: \(path)"
        }
    }
}

public struct ReportComparison: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public let name: String
        public let before: (precision: Double, recall: Double, fieldAccuracy: Double?)
        public let after: (precision: Double, recall: Double, fieldAccuracy: Double?)
        public static func == (a: Change, b: Change) -> Bool {
            a.name == b.name && a.before == b.before && a.after == b.after
        }
    }
    public let precisionDelta: Double
    public let recallDelta: Double
    public let fieldAccuracyDelta: Double?
    public let classificationDelta: Double
    public let secondsDelta: Double
    public let changedCases: [Change]

    public var text: String {
        func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
        var lines = ["precision \(signed(precisionDelta))  recall \(signed(recallDelta))  field accuracy \(fieldAccuracyDelta.map(signed) ?? "n/a")  classification \(signed(classificationDelta))  seconds/case \(String(format: "%+.1f", secondsDelta))"]
        for c in changedCases {
            func f(_ x: (precision: Double, recall: Double, fieldAccuracy: Double?)) -> String {
                String(format: "p %.2f r %.2f f ", x.precision, x.recall) + (x.fieldAccuracy.map { String(format: "%.2f", $0) } ?? "n/a")
            }
            lines.append("changed   \(c.name): \(f(c.before)) -> \(f(c.after))")
        }
        if changedCases.isEmpty { lines.append("no case changed") }
        return lines.joined(separator: "\n")
    }
}

/// The result of one eval run: settings, numbers, and every case with its misses, unexpected findings and the
/// raw model answers (so a run can be replayed without the model).
public struct EvalReport: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let createdAt: Date
    public let settings: EvalSettings
    public let ranWhileAppBusy: Bool
    public let overall: OverallNumbers
    public let summary: Summary
    public let cases: [CaseReport]

    public static func build(settings: EvalSettings, cases items: [(GoldenCase, CaseResult)], ranWhileAppBusy: Bool,
                             createdAt: Date = Date()) -> EvalReport {
        let scored = items.map { ($0.0, Metrics.score($0.0, $0.1, thresholds: settings.thresholds)) }
        let summary = Metrics.summarise(scored)
        let o = summary.overall
        let overall = OverallNumbers(cases: o.cases, precision: o.precision, recall: o.recall, fieldAccuracy: o.fieldAccuracy,
                                     classificationAccuracy: o.classificationAccuracy, meanSeconds: o.meanSeconds,
                                     ocrExactRate: o.ocrExactRate, ocrOverlapRate: o.ocrOverlapRate,
                                     contextAccuracy: summary.contextAccuracy, wrongHighConfidenceTags: summary.wrongHighConfidenceTags)
        let cases = zip(items, scored).map { item, pair -> CaseReport in
            let (golden, result) = item
            let missed = pair.1.missed.map { expected in
                MissedFinding(expected: expected, nearestFoundTitle: result.findings.max {
                    Matcher.titleSimilarity($0.title, expected.title) < Matcher.titleSimilarity($1.title, expected.title) }?.title)
            }
            return CaseReport(name: golden.name, origin: golden.origin.rawValue, expectedKind: golden.expected.screenKind,
                              foundKind: result.kind, score: pair.1, missed: missed, steps: result.steps)
        }
        return EvalReport(version: currentVersion, createdAt: createdAt, settings: settings, ranWhileAppBusy: ranWhileAppBusy,
                          overall: overall, summary: summary, cases: cases)
    }

    // MARK: JSON

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EvalReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalReport.self, from: data)
    }

    /// Reports of local cases contain model answers about real screens: they never go under a tracked folder.
    public func write(to url: URL) throws {
        if cases.contains(where: { $0.origin == GoldenOrigin.local.rawValue }), url.path.contains("/eval/golden/synthetic/") {
            throw EvalReportError.localCasesInTrackedFolder(url.path)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url)
    }

    // MARK: Comparison

    public static func compare(_ a: EvalReport, _ b: EvalReport) -> ReportComparison {
        func delta(_ x: Double?, _ y: Double?) -> Double? { x != nil && y != nil ? y! - x! : nil }
        let before = Dictionary(a.cases.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [ReportComparison.Change] = []
        for after in b.cases {
            guard let old = before[after.name] else { continue }
            let differs = abs(old.precision - after.precision) > 1e-9 || abs(old.recall - after.recall) > 1e-9
                || (delta(old.fieldAccuracy, after.fieldAccuracy).map { abs($0) > 1e-9 } ?? (old.fieldAccuracy != after.fieldAccuracy))
            if differs {
                changes.append(.init(name: after.name, before: (old.precision, old.recall, old.fieldAccuracy),
                                     after: (after.precision, after.recall, after.fieldAccuracy)))
            }
        }
        return ReportComparison(precisionDelta: b.overall.precision - a.overall.precision, recallDelta: b.overall.recall - a.overall.recall,
                                fieldAccuracyDelta: delta(a.overall.fieldAccuracy, b.overall.fieldAccuracy),
                                classificationDelta: b.overall.classificationAccuracy - a.overall.classificationAccuracy,
                                secondsDelta: b.overall.meanSeconds - a.overall.meanSeconds, changedCases: changes)
    }

    // MARK: Text

    public var text: String {
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        let t = settings.thresholds
        var lines = ["memorri-eval  model \(settings.model)  size \(settings.size)  think \(settings.think)  (titles ≥ \(f(t.titleSimilarity)), ±\(Int(t.minutes)) min)"]
        let synthetic = cases.filter { $0.origin == "synthetic" }.count, local = cases.filter { $0.origin == "local" }.count
        lines.append("cases \(overall.cases)  (synthetic \(synthetic), local \(local))   mean \(String(format: "%.1f", overall.meanSeconds)) s/case")
        lines.append("findings   precision \(f(overall.precision))  recall \(f(overall.recall))  field accuracy \(overall.fieldAccuracy.map(f) ?? "n/a")")
        let kinds = summary.byKind.keys.sorted().map { "\($0) \(f(summary.byKind[$0]!.classificationAccuracy))" }.joined(separator: "  ")
        lines.append("kind       accuracy \(f(overall.classificationAccuracy))   \(kinds)")
        if !summary.tagAccuracy.isEmpty {
            let tags = summary.tagAccuracy.keys.sorted().map { "\($0) \(summary.tagAccuracy[$0]!.accuracy.map(f) ?? "n/a")" }.joined(separator: "  ")
            lines.append("tags       \(tags)   (wrong with high confidence: \(overall.wrongHighConfidenceTags))")
        }
        if let exact = overall.ocrExactRate { lines.append("reading    exact \(f(exact))  box overlap \(overall.ocrOverlapRate.map(f) ?? "n/a")") }
        if let context = overall.contextAccuracy { lines.append("context    accuracy \(f(context))") }
        if ranWhileAppBusy { lines.append("note       ran while the app was busy") }
        for c in cases {
            for m in c.missed {
                let e = m.expected
                lines.append("missed     \(c.name): \"\(e.title)\"\(Self.dates(e.start, e.end, e.due, e.remind, allDay: e.allDay ?? false, inferred: e.inferred ?? [])) (nearest found: \(m.nearestFoundTitle ?? "none"))")
            }
            for u in c.score.unexpected {
                let f = u.found
                lines.append("unexpected \(c.name): \"\(f.title)\"\(Self.dates(f.start, f.end, f.due, f.remind, allDay: f.allDay, inferred: f.inferred)) (nearest expected: \(u.closestExpectedTitle ?? "none"))")
            }
            for problem in c.score.tagProblems ?? [] { lines.append("tag        \(c.name): \(problem)") }
            for d in c.score.disagreements { lines.append("disagrees  \(c.name): \"\(d.title)\" is not in the text it cites") }
        }
        return lines.joined(separator: "\n")
    }

    /// The dates of a finding in UTC, for reading the list of misses: ` [start 2026-10-14 12:30, end 2026-10-14 13:00 inferred]`.
    static func dates(_ start: Date?, _ end: Date?, _ due: Date?, _ remind: Date?, allDay: Bool, inferred: [String]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parts: [String] = []
        for (name, value) in [("start", start), ("end", end), ("due", due), ("remind", remind)] {
            guard let value else { continue }
            parts.append("\(name) \(formatter.string(from: value))\(inferred.contains(name) ? " inferred" : "")")
        }
        if allDay { parts.append("all day") }
        return parts.isEmpty ? "" : " [" + parts.joined(separator: ", ") + " UTC]"
    }
}
