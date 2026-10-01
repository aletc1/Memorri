import Testing
@testable import MemorriCore

@Suite struct TitleNormaliserTests {
    @Test func foldsCaseAndAccents() {
        #expect(TitleNormaliser.normalise("Revisión de Presupuesto") == "revision de presupuesto")
        #expect(TitleNormaliser.normalise("REVISION") == TitleNormaliser.normalise("Revisión"))
        #expect(TitleNormaliser.normalise("Ünïcödé Çafé") == "unicode cafe")
    }

    @Test func collapsesSpacesAndDropsPunctuation() {
        #expect(TitleNormaliser.normalise("  Daily   standup  ") == "daily standup")
        #expect(TitleNormaliser.normalise("Q3: Planning (draft)!") == "q3 planning draft")
        #expect(TitleNormaliser.normalise("stand-up") == "stand up")
        #expect(TitleNormaliser.normalise("Anna's review") == "annas review")
        #expect(TitleNormaliser.normalise("Anna’s review") == "annas review")
    }

    @Test func removesATrailingEllipsis() {
        #expect(TitleNormaliser.normalise("Quarterly planning with the cust…") == "quarterly planning with the cust")
        #expect(TitleNormaliser.normalise("Quarterly planning with the cust...") == "quarterly planning with the cust")
        #expect(TitleNormaliser.normalise("Quarterly planning with the cust..") == "quarterly planning with the cust")
        #expect(TitleNormaliser.normalise("Quarterly planning with the cust … ") == "quarterly planning with the cust")
    }

    @Test func emptyAndPunctuationOnlyTitlesGiveAnEmptyString() {
        #expect(TitleNormaliser.normalise("") == "")
        #expect(TitleNormaliser.normalise("   \n\t ") == "")
        #expect(TitleNormaliser.normalise("…") == "")
        #expect(TitleNormaliser.normalise("?!") == "")
    }

    @Test func keepsOtherScriptsAsTheyAre() {
        #expect(TitleNormaliser.normalise("会議 10時") == "会議 10時")
        #expect(TitleNormaliser.normalise("Встреча команды") == "встреча команды")
    }

    @Test func isIdempotent() {
        for title in ["Revisión de  presupuesto…", "A-B c", "Q3: plan"] {
            let once = TitleNormaliser.normalise(title)
            #expect(TitleNormaliser.normalise(once) == once)
        }
    }
}
