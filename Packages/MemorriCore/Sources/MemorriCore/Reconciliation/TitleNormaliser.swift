import Foundation

/// The form of a title that matching compares: case and accents folded, punctuation gone, a trailing ellipsis removed
/// (calendars cut titles at the block width) and single spaces between words.
public enum TitleNormaliser {
    public static func normalise(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "…" || last == "." || last == " " { text.removeLast() }
        text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result = ""
        for character in text {
            if "'’`".contains(character) { continue }
            if character.isLetter || character.isNumber { result.append(character) }
            else { result.append(" ") }
        }
        return result.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}
