import Foundation

/// The drawn golden cases: pictures made in code whose right answers are known by construction (ADR 0015).
/// Nothing here is random and nothing reads the clock, so generating twice gives the same bytes.
public enum SyntheticCases {
    static let cases: [SyntheticCase] = {
        do { return try SyntheticCalendars.cases() + SyntheticMessages.cases() + SyntheticWindows.cases() }
        catch { fatalError("synthetic cases cannot be drawn: \(error)") }
    }()

    /// The cases as golden cases (without their folders), for callers that only need names and answers.
    public static var all: [GoldenCaseSummary] { cases.map { GoldenCaseSummary(name: $0.name, expected: $0.expected, meta: $0.meta, features: $0.features) } }

    /// Writes every case to `folder/<name>/`, creating `folder` when needed. Returns the case folders.
    @discardableResult
    public static func generate(into folder: URL) throws -> [URL] {
        try cases.map { item in
            let target = folder.appendingPathComponent(item.name, isDirectory: true)
            try item.golden.write(to: target, picture: item.picture)
            return target
        }
    }
}

public struct GoldenCaseSummary: Sendable {
    public let name: String
    public let expected: GoldenExpected
    public let meta: GoldenMeta
    public let features: Set<String>
}
