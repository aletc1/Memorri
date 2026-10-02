import Foundation

/// How search sees text: case and accents folded away, words split on anything that is not a letter or a digit. The index folds the same way
/// (`unicode61 remove_diacritics 2`), so what matches in the index also matches here, where the matching words are marked.
public enum SearchText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    /// The folded words of `text`, in order.
    public static func words(_ text: String) -> [String] {
        tokens(in: text).map(\.folded)
    }

    /// The words of `text` with where each one is.
    static func tokens(in text: String) -> [(range: Range<String.Index>, folded: String)] {
        var result: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isWordCharacter(character) {
                if start == nil { start = index }
            } else if let begin = start {
                result.append((begin..<index, fold(String(text[begin..<index]))))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start { result.append((begin..<text.endIndex, fold(String(text[begin..<text.endIndex])))) }
        return result
    }

    /// The ranges, in `text`, of the words that match the query: a word equal to a query word or a phrase word, or, for the last word typed,
    /// one that begins with it. Excluded words mark nothing.
    public static func marks(of terms: SearchQuery.Terms, in text: String) -> [Range<String.Index>] {
        var whole = Set(terms.phrases.flatMap { $0 })
        var prefix: String?
        for (offset, word) in terms.words.enumerated() {
            if terms.prefixLast, offset == terms.words.count - 1 { prefix = word } else { whole.insert(word) }
        }
        return tokens(in: text).compactMap { token in
            if whole.contains(token.folded) { return token.range }
            if let prefix, token.folded.hasPrefix(prefix) { return token.range }
            return nil
        }
    }
}
