import Foundation
import Testing
@testable import MemorriCore

@Suite struct SearchItemsTests {
    private func ids(_ results: SearchResults) -> [String] { results.items.map(\.id) }

    @Test func anItemIsFoundByItsTitleWithoutCaseOrAccents() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Café - Pruebas")
        try f.addItem("b", title: "Dentist")
        for text in ["cafe pru", "CAFE", "Café Pruebas", "pruebas"] {
            let results = try await f.service.search(SearchQuery(text: text))
            #expect(ids(results) == ["a"], "\(text)")
        }
        let hit = try #require(try await f.service.search(SearchQuery(text: "cafe pru")).items.first)
        #expect(hit.matchedIn == .title && hit.kind == .appointment)
        #expect(hit.title.marks.map { String(hit.title.text[$0]) } == ["Café", "Pruebas"])
    }

    @Test func notesPlacePeopleAndAliasesAreSearchedAndNamed() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Weekly sync", notes: "bring the budget deck", place: "Sala Azul", people: ["Anna Example", "Luis"], aliases: ["Sprint planning (moved)"])
        let expected: [(String, SearchField)] = [("budget", .notes), ("azul", .place), ("example", .people), ("moved", .alias), ("weekly", .title)]
        for (text, field) in expected {
            let hit = try #require(try await f.service.search(SearchQuery(text: text)).items.first, "\(text)")
            #expect(hit.matchedIn == field, "\(text)")
            if field != .title { #expect(hit.snippet?.marks.isEmpty == false, "\(text)") }
        }
    }

    @Test func titleWinsWhenTheWordIsInTheTitleAndElsewhere() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Budget review", notes: "budget")
        let hit = try #require(try await f.service.search(SearchQuery(text: "budget")).items.first)
        #expect(hit.matchedIn == .title)
    }

    @Test func everyWordIsRequiredAndTheLastMatchesByItsBeginning() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Daily standup", notes: "room four")
        try f.addItem("b", title: "Daily review")
        #expect(ids(try await f.service.search(SearchQuery(text: "daily"))).sorted() == ["a", "b"])
        #expect(ids(try await f.service.search(SearchQuery(text: "daily stand"))) == ["a"])
        #expect(ids(try await f.service.search(SearchQuery(text: "dai standup"))) == [])     // only the last word is a prefix
        #expect(ids(try await f.service.search(SearchQuery(text: "daily standup four"))) == ["a"])
    }

    @Test func quotedPhrasesMustBeAdjacentAndExcludedWordsRemoveItems() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Daily standup")
        try f.addItem("b", title: "Standup daily notes")
        #expect(ids(try await f.service.search(SearchQuery(text: "\"daily standup\""))) == ["a"])
        #expect(ids(try await f.service.search(SearchQuery(text: "standup -notes"))) == ["a"])
        #expect(ids(try await f.service.search(SearchQuery(text: "standup -\"daily standup\""))) == ["b"])
    }

    @Test func aTitleMatchRanksAboveANotesMatchAndTiesAreNewestFirst() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("notes", title: "Other", notes: "invoice", lastSeen: SearchFixture.date(20))
        try f.addItem("title-old", title: "Invoice", lastSeen: SearchFixture.date(2))
        try f.addItem("title-new", title: "Invoice", lastSeen: SearchFixture.date(9))
        let results = try await f.service.search(SearchQuery(text: "invoice"))
        #expect(ids(results) == ["title-new", "title-old", "notes"])
    }

    @Test func aRareWordRanksItsItemAboveItemsThatMatchOnlyACommonOne() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        for n in 0..<20 { try f.addItem("common\(n)", title: "Meeting with the team \(n)", lastSeen: SearchFixture.date(25)) }
        try f.addItem("rare", title: "Meeting with Zenobia", lastSeen: SearchFixture.date(1))
        let results = try await f.service.search(SearchQuery(text: "meeting zenobia"))
        #expect(ids(results) == ["rare"])
        let either = try await f.service.search(SearchQuery(text: "zenobia"))
        #expect(ids(either) == ["rare"])
    }

    @Test func pagingUsesTheLimitAndTheOffsetAndSaysWhenThereIsMore() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        for n in 1...25 { try f.addItem("i\(n)", title: "Review \(n)", lastSeen: SearchFixture.date(n)) }
        let first = try await f.service.search(SearchQuery(text: "review"), itemLimit: 20)
        #expect(first.items.count == 20 && first.moreItems)
        let second = try await f.service.search(SearchQuery(text: "review"), itemLimit: 20, itemOffset: 20)
        #expect(second.items.count == 5 && !second.moreItems)
        #expect(Set(ids(first) + ids(second)).count == 25)
    }

    @Test func aQueryThatIsNotSearchableReturnsNothingWithoutThrowing() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        try f.addItem("a", title: "Daily standup")
        for text in ["", "a", "!!!", "-standup", "\""] {
            #expect(try await f.service.search(SearchQuery(text: text)) == .empty, "\(text)")
        }
        for text in ["foo\"bar* AND (", "NEAR(a b)", "title:standup", "standup OR", "^daily", "daily:", "(((", "x*y"] {
            _ = try await f.service.search(SearchQuery(text: text))       // whatever it finds, it does not throw
        }
    }

    @Test func everyWordOfEveryFieldFindsItsItem() async throws {
        let f = try SearchFixture(); defer { f.cleanUp() }
        let titles = ["Café - Pruebas", "Reunión de seguimiento", "Dentista Ñandú", "Submit grant proposal", "Informe trimestral"]
        for (n, title) in titles.enumerated() {
            try f.addItem("i\(n)", title: title, notes: "nota\(n) especial", place: "Lugar\(n)", people: ["Persona\(n)"], aliases: ["Alias\(n) distinto"])
        }
        for (n, title) in titles.enumerated() {
            var words = SearchText.words(title) + ["nota\(n)", "lugar\(n)", "persona\(n)", "alias\(n)", "distinto", "especial"]
            words = words.filter { $0.count >= 2 }
            for word in words where !["distinto", "especial", "de"].contains(word) {
                let found = try await f.service.search(SearchQuery(text: word.uppercased())).items.map(\.id)
                #expect(found.contains("i\(n)"), "\(word)")
            }
        }
    }
}
