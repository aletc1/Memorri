import Foundation

/// One picture size and what the pipeline scored at it.
public struct SweepRow: Sendable, Equatable, Codable {
    public let size: Int
    public let cases: Int
    public let precision: Double
    public let recall: Double
    public let fieldAccuracy: Double?
    public let meanSeconds: Double

    public var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
}

public struct SizeSweepResult: Sendable, Equatable, Codable {
    public let rows: [SweepRow]
    public let recommended: Int
    public let reason: String

    public var text: String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "n/a" }
        func pad(_ text: String, _ width: Int) -> String { text + String(repeating: " ", count: max(0, width - text.count)) }
        var lines = [pad("size", 7) + pad("cases", 7) + pad("precision", 11) + pad("recall", 8) + pad("F1", 6) + pad("field accuracy", 16) + "mean seconds"]
        for row in rows {
            lines.append(pad("\(row.size)", 7) + pad("\(row.cases)", 7) + pad(f(row.precision), 11) + pad(f(row.recall), 8) + pad(f(row.f1), 6)
                         + pad(f(row.fieldAccuracy), 16) + String(format: "%.1f", row.meanSeconds))
        }
        lines.append("recommended \(recommended): \(reason)")
        return lines.joined(separator: "\n")
    }
}

/// Runs the golden set at several picture sizes and recommends a default (research R18).
public struct SizeSweep: Sendable {
    public static let defaultSizes = [1024, 1536, 2048, 3072]
    /// The size that stays when nothing smaller is as good.
    public static let baseline = 2048
    /// How far from the best a size may be and still count as as good.
    public static let tolerance = 0.02

    let runner: @Sendable (Int) -> EvalRunner

    /// `runner` makes an `EvalRunner` whose analyser builds its pictures at the given size.
    public init(runner: @escaping @Sendable (Int) -> EvalRunner) { self.runner = runner }

    public func run(cases: [GoldenCase], sizes: [Int] = SizeSweep.defaultSizes, allowBusy: Bool = false,
                    progress: (@Sendable (String) -> Void)? = nil) async throws -> SizeSweepResult {
        var rows: [SweepRow] = []
        for size in sizes.sorted() {
            progress?("size \(size)")
            let report = try await runner(size).run(cases: cases, allowBusy: allowBusy, progress: progress)
            let overall = report.overall
            rows.append(SweepRow(size: size, cases: overall.cases, precision: overall.precision, recall: overall.recall,
                                 fieldAccuracy: overall.fieldAccuracy, meanSeconds: overall.meanSeconds))
        }
        let choice = Self.recommend(rows)
        return SizeSweepResult(rows: rows, recommended: choice.size, reason: choice.reason)
    }

    /// The smallest size whose findings F1 and field accuracy are each within 0.02 of the best. The default stays when no size
    /// below it qualifies, and a larger size that would be needed is mentioned, not chosen.
    public static func recommend(_ rows: [SweepRow]) -> (size: Int, reason: String) {
        guard let bestF1 = rows.map(\.f1).max() else { return (baseline, "nothing was measured") }
        if bestF1 == 0 { return (baseline, "no size found anything, so nothing can be told apart") }
        let bestField = rows.compactMap(\.fieldAccuracy).max()
        let qualifying = rows.filter { row in
            row.f1 >= bestF1 - tolerance && (bestField.map { (row.fieldAccuracy ?? 0) >= $0 - tolerance } ?? true)
        }.sorted { $0.size < $1.size }
        guard let smallest = qualifying.first else { return (baseline, "nothing qualified") }
        if smallest.size < baseline {
            return (smallest.size, "the smallest size within \(tolerance) of the best findings F1 (\(String(format: "%.2f", bestF1))) and field accuracy")
        }
        if smallest.size > baseline {
            return (baseline, "no smaller size is as good; \(smallest.size) scored higher but the default stays")
        }
        return (baseline, "no smaller size is as good as \(baseline)")
    }
}
