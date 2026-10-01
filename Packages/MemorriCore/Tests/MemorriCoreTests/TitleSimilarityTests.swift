import Testing
@testable import MemorriCore

@Suite struct TitleSimilarityTests {
    private func score(_ a: String, _ b: String) -> (value: Double, relation: TitleSimilarity.Relation) {
        TitleSimilarity.score(TitleNormaliser.normalise(a), TitleNormaliser.normalise(b))
    }

    @Test func equalTitlesScoreOne() {
        let result = score("Daily Standup", "daily standup!")
        #expect(result.value == 1 && result.relation == .equal)
    }

    @Test func aTitleCutMidWordIsATruncation() {
        let result = score("Quarterly planning with the cust…", "Quarterly planning with the customer")
        #expect(result.value == 0.95 && result.relation == .truncation)
        let reversed = score("Quarterly planning with the customer", "Quarterly planning with the cust…")
        #expect(reversed.value == 0.95 && reversed.relation == .truncation)
    }

    @Test func aPrefixAtAWordBoundaryIsATruncationToo() {
        let result = score("Daily standup", "Daily standup with the team")
        #expect(result.value == 0.95 && result.relation == .truncation)
    }

    @Test func aPrefixShorterThanEightCharactersIsOnlyFuzzy() {
        let result = score("Lunch", "Lunch with Anna")
        #expect(result.relation == .fuzzy)
        #expect(result.value <= 0.5)
        let seven = score("Standup", "Standup with the team")
        #expect(seven.relation == .fuzzy)
    }

    @Test func smallSpellingDifferencesScoreHighThroughEditDistance() {
        let result = score("Daily standup", "Daily stand up")
        #expect(result.relation == .fuzzy && result.value >= 0.85 && result.value < 1)
        #expect(score("Budget reveiw", "Budget review").value >= 0.8)
    }

    @Test func sharedWordsRaiseTheScoreOfReorderedTitles() {
        let result = score("Review of the budget", "Budget review")
        #expect(result.value > 0.6 && result.value < 0.9)
    }

    @Test func differentMeetingsWithASharedWordStayBelowTheMergeLine() {
        let result = score("Design review", "Budget review")
        #expect(result.value < 0.9 && result.value >= 0.4)
        #expect(score("Anna 1:1", "Quarterly planning").value < 0.4)
    }

    @Test func emptyTitlesScoreZero() {
        #expect(TitleSimilarity.score("", "daily standup").value == 0)
        #expect(TitleSimilarity.score("", "").value == 0)
    }

    @Test func everyAliasOfTheCandidateIsComparedAndTheBestCounts() {
        let aliases = ["Reunión diaria", "Daily standup with the team"]
        let best = TitleSimilarity.best(of: TitleNormaliser.normalise("Daily standup…"), against: aliases.map(TitleNormaliser.normalise))
        #expect(best.value == 0.95 && best.relation == .truncation)
        #expect(TitleSimilarity.best(of: "x", against: []).value == 0)
    }
}
