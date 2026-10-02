import Foundation

/// What the user typed and the filters in force (spec 007). Pure: parsing never fails, and nothing typed reaches the index unquoted.
public struct SearchQuery: Sendable, Equatable {
    public enum Kinds: Sendable, Equatable, Hashable { case appointments, tasks, reminders, captures }
    public enum Context: Sendable, Equatable { case any, none, one(String) }

    public struct Terms: Sendable, Equatable {
        /// Single words, folded.
        public var words: [String] = []
        /// Quoted phrases, each a list of folded words.
        public var phrases: [[String]] = []
        /// Words (or, when quoted, phrases joined by a space) that must not be there.
        public var excluded: [String] = []
        /// True when the last thing typed was a bare word: it is then matched by its beginning, as the user is still typing it.
        public var prefixLast = false

        public init(words: [String] = [], phrases: [[String]] = [], excluded: [String] = [], prefixLast: Bool = false) {
            self.words = words; self.phrases = phrases; self.excluded = excluded; self.prefixLast = prefixLast
        }
    }

    public var text: String
    public var kinds: Set<Kinds>
    public var context: Context
    public var dates: ClosedRange<Date>?
    public var includeDismissed: Bool

    public init(text: String, kinds: Set<Kinds> = [], context: Context = .any, dates: ClosedRange<Date>? = nil, includeDismissed: Bool = false) {
        self.text = text; self.kinds = kinds; self.context = context; self.dates = dates; self.includeDismissed = includeDismissed
    }

    public var terms: Terms { Self.parse(text) }

    /// True when any filter is on (the text does not count).
    public var hasFilters: Bool { !kinds.isEmpty || context != .any || dates != nil || includeDismissed }

    /// Switches every filter off and keeps the text.
    public mutating func clearFilters() { kinds = []; context = .any; dates = nil; includeDismissed = false }

    /// A positive term and at least two letters or digits among the positive terms.
    public var isSearchable: Bool {
        let terms = self.terms
        let letters = (terms.words + terms.phrases.flatMap { $0 }).reduce(0) { $0 + $1.count }
        return letters >= 2
    }

    /// The text for the index's `MATCH`, or nil when the query is not searchable. Every term is quoted, the last bare word gets the prefix star,
    /// positive terms are joined with `AND` and each excluded one follows with `NOT`.
    public var matchExpression: String? {
        guard isSearchable else { return nil }
        let terms = self.terms
        var positives = terms.words.enumerated().map { offset, word -> String in
            let star = terms.prefixLast && offset == terms.words.count - 1 ? "*" : ""
            return "\"\(word)\"\(star)"
        }
        positives += terms.phrases.filter { !$0.isEmpty }.map { "\"\($0.joined(separator: " "))\"" }
        let negatives = terms.excluded.map { " NOT \"\($0)\"" }.joined()
        return "(" + positives.joined(separator: " AND ") + ")" + negatives
    }

    private static func parse(_ text: String) -> Terms {
        var terms = Terms()
        var index = text.startIndex
        var lastPositiveWasWord = false
        func atEnd() -> Bool { index >= text.endIndex }
        while !atEnd() {
            let character = text[index]
            if character.isWhitespace { index = text.index(after: index); continue }
            var excluded = false
            if character == "-" {
                let next = text.index(after: index)
                if next < text.endIndex, !text[next].isWhitespace { excluded = true; index = next } else { index = next; continue }
            }
            if !atEnd(), text[index] == "\"" {
                index = text.index(after: index)
                let begin = index
                while !atEnd(), text[index] != "\"" { index = text.index(after: index) }
                let words = SearchText.words(String(text[begin..<index]))
                if !atEnd() { index = text.index(after: index) }          // the closing quote
                guard !words.isEmpty else { continue }
                if excluded { terms.excluded.append(words.joined(separator: " ")) } else { terms.phrases.append(words); lastPositiveWasWord = false }
                continue
            }
            let begin = index
            while !atEnd(), !text[index].isWhitespace, text[index] != "\"" { index = text.index(after: index) }
            let words = SearchText.words(String(text[begin..<index]))
            if excluded { terms.excluded += words } else if !words.isEmpty { terms.words += words; lastPositiveWasWord = true }
        }
        terms.prefixLast = lastPositiveWasWord
        return terms
    }
}
