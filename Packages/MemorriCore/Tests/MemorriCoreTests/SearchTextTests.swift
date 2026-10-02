import Foundation
import Testing
@testable import MemorriCore

@Suite struct SearchTextTests {
    @Test func foldingIgnoresCaseAndAccents() {
        #expect(SearchText.fold("Café") == "cafe")
        #expect(SearchText.fold("CAFÉ") == "cafe")
        #expect(SearchText.fold("Niño") == "nino")
        #expect(SearchText.fold("ÀÉÎõü") == "aeiou")
    }

    @Test func wordsSplitOnAnythingThatIsNotALetterOrDigit() {
        #expect(SearchText.words("Café - Pruebas (v2)") == ["cafe", "pruebas", "v2"])
        #expect(SearchText.words("Invoice 2291, due Friday!") == ["invoice", "2291", "due", "friday"])
        #expect(SearchText.words("  ---  ") == [])
        #expect(SearchText.words("") == [])
    }

    private func terms(_ text: String) -> SearchQuery.Terms { SearchQuery(text: text).terms }

    private func marked(_ text: String, _ query: String) -> [String] {
        SearchText.marks(of: terms(query), in: text).map { String(text[$0]) }
    }

    @Test func marksCoverTheWordsThatMatchInTheOriginalText() {
        #expect(marked("Café - Pruebas finales", "cafe pruebas") == ["Café", "Pruebas"])
        #expect(marked("Daily STANDUP", "standup") == ["STANDUP"])
    }

    @Test func theLastWordMatchesByItsBeginningAndTheOthersWhole() {
        #expect(marked("Pruebas de carga", "pru") == ["Pruebas"])
        #expect(marked("Pruebas de carga", "pru de") == ["de"])      // "pru" is not the last word, so it must be whole
        #expect(marked("Pruebas de carga", "pruebas ca") == ["Pruebas", "carga"])
    }

    @Test func aPhraseMarksItsWordsAndAnExcludedWordMarksNothing() {
        #expect(marked("the daily standup, then lunch", "\"daily standup\"") == ["daily", "standup"])
        #expect(marked("budget review", "review -budget") == ["review"])
    }

    @Test func marksAreInOrderAndDoNotOverlap() {
        let text = "ana ana-maria Ana"
        let ranges = SearchText.marks(of: terms("ana"), in: text)
        #expect(ranges.count == 3)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound })
    }
}
