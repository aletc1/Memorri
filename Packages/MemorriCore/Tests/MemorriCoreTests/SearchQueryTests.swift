import Foundation
import Testing
@testable import MemorriCore

@Suite struct SearchQueryTests {
    private func query(_ text: String) -> SearchQuery { SearchQuery(text: text) }

    @Test func wordsPhrasesAndExclusionsAreParsed() {
        #expect(query("cafe pru").terms.words == ["cafe", "pru"])
        #expect(query("Café PRU").terms.words == ["cafe", "pru"])
        #expect(query("\"daily standup\" review").terms.phrases == [["daily", "standup"]])
        #expect(query("\"daily standup\" review").terms.words == ["review"])
        #expect(query("review -budget").terms.excluded == ["budget"])
        #expect(query("review -\"old plan\"").terms.excluded == ["old plan"])
        #expect(query("a-b").terms.words == ["a", "b"])               // a minus inside a word is not an exclusion
        #expect(query("\"unclosed phrase here").terms.phrases == [["unclosed", "phrase", "here"]])
    }

    @Test func aQueryNeedsAPositiveTermAndTwoLetters() {
        #expect(!query("").isSearchable)
        #expect(!query("   ").isSearchable)
        #expect(!query("a").isSearchable)
        #expect(!query("!!!").isSearchable)
        #expect(!query("-budget").isSearchable)
        #expect(!query("-").isSearchable)
        #expect(query("ab").isSearchable)
        #expect(query("a b").isSearchable)
        #expect(query("2291").isSearchable)
        #expect(query("\"a b\"").isSearchable)
    }

    @Test func theExpressionQuotesEveryTermAndStarsTheLastWord() {
        #expect(query("cafe pru").matchExpression == "(\"cafe\" AND \"pru\"*)")
        #expect(query("pruebas").matchExpression == "(\"pruebas\"*)")
        #expect(query("\"daily standup\" review").matchExpression == "(\"review\"* AND \"daily standup\")")
        #expect(query("\"daily standup\"").matchExpression == "(\"daily standup\")")       // a phrase is never a prefix
        #expect(query("review -budget -\"old plan\"").matchExpression == "(\"review\"*) NOT \"budget\" NOT \"old plan\"")
        #expect(query("a").matchExpression == nil)
        #expect(query("-budget").matchExpression == nil)
    }

    @Test func nothingTypedReachesTheExpressionUnquoted() {
        for text in ["foo\"bar", "a*", "title:foo", "(foo)", "foo OR bar", "NEAR(a b)", "foo AND", "NOT foo", "^foo", "foo bar baz*", "'", "\\", "{x}", "- - -"] {
            let expression = query(text).matchExpression
            guard let expression else { continue }
            // Every bare operator word is inside quotes, and the only characters outside quotes are structure we wrote ourselves.
            var outside = ""
            var inside = false
            for character in expression { if character == "\"" { inside.toggle() } else if !inside { outside.append(character) } }
            #expect(!inside, "unbalanced quotes for \(text)")
            let allowed = Set("() *")
            #expect(outside.allSatisfy { allowed.contains($0) || "ANDOT".contains($0) }, "unquoted text for \(text): \(outside)")
            let leftover = outside.replacingOccurrences(of: "AND", with: "").replacingOccurrences(of: "NOT", with: "")
            let hasLetter = leftover.contains { $0.isLetter }
            #expect(!hasLetter, "unquoted word for \(text)")
        }
    }

    @Test func aVeryLongTextDoesNotFail() {
        let long = String(repeating: "palabra ", count: 300)
        #expect(query(long).isSearchable)
        #expect(query(long).matchExpression != nil)
    }

    @Test func filtersDefaultToEverything() {
        let q = query("x y")
        #expect(q.kinds.isEmpty && q.context == .any && q.dates == nil && !q.includeDismissed)
    }
}
