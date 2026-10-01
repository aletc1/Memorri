import Foundation

/// How alike two normalised titles are (research R6): equal, one cut short of the other (calendars cut titles at the block
/// width, often mid-word), or by edit distance and shared words.
public enum TitleSimilarity {
    public enum Relation: Sendable, Equatable { case equal, truncation, fuzzy }

    /// A prefix counts as a truncation only when it is at least this long: short words are prefixes of too many titles.
    static let minimumTruncatedLength = 8
    static let truncationScore = 0.95

    public static func score(_ a: String, _ b: String) -> (value: Double, relation: Relation) {
        if a.isEmpty || b.isEmpty { return (0, .fuzzy) }
        if a == b { return (1, .equal) }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= minimumTruncatedLength, long.hasPrefix(short) { return (truncationScore, .truncation) }
        return (max(editSimilarity(a, b), tokenDice(a, b)), .fuzzy)
    }

    /// The best score of `title` against every title an item is known by.
    public static func best(of title: String, against others: [String]) -> (value: Double, relation: Relation) {
        others.map { score(title, $0) }.max { $0.value < $1.value } ?? (0, .fuzzy)
    }

    private static func editSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    private static func tokenDice(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }
}
