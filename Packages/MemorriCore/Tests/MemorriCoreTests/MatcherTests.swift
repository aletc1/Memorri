import Foundation
import Testing
@testable import MemorriCore

@Suite struct MatcherTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_986_400)

    private func expected(_ title: String, kind: String = "appointment", start: Date? = nil, due: Date? = nil, allDay: Bool? = nil) -> ExpectedFinding {
        ExpectedFinding(kind: kind, title: title, start: start, due: due, allDay: allDay)
    }
    private func found(_ title: String, kind: String = "appointment", start: Date? = nil, due: Date? = nil, allDay: Bool = false) -> FoundFinding {
        FoundFinding(kind: kind, title: title, start: start, due: due, allDay: allDay)
    }
    private func pairs(_ e: [ExpectedFinding], _ f: [FoundFinding]) -> MatchResult { Matcher.match(expected: e, found: f) }

    @Test func anExactTitleAtTheSameTimeMatches() {
        let result = pairs([expected("Team sync", start: t0)], [found("Team sync", start: t0)])
        #expect(result.pairs.count == 1 && result.unmatchedExpected.isEmpty && result.unmatchedFound.isEmpty)
    }

    @Test func caseSpacesAndPunctuationAreIgnored() {
        #expect(pairs([expected("Team sync", start: t0)], [found("  TEAM-sync! ", start: t0)]).pairs.count == 1)
    }

    @Test func oneTitleContainingTheOtherMatches() {
        #expect(pairs([expected("Team sync", start: t0)], [found("Team sync (weekly)", start: t0)]).pairs.count == 1)
        #expect(pairs([expected("Design review with the vendor", start: t0)], [found("Design review", start: t0)]).pairs.count == 1)
    }

    @Test func aVeryShortTitleInsideAnotherDoesNotCountAsContainment() {
        #expect(pairs([expected("Budget workshop", start: t0)], [found("ok", start: t0)]).pairs.isEmpty)
        #expect(pairs([expected("a", start: t0)], [found("banana split review", start: t0)]).pairs.isEmpty)
    }

    @Test func similarityIsCheckedAroundTheThreshold() {
        let base = String(repeating: "a", count: 100)
        let at79 = String(repeating: "a", count: 79) + String(repeating: "b", count: 21)
        let at81 = String(repeating: "a", count: 81) + String(repeating: "b", count: 19)
        #expect(Matcher.titleSimilarity(base, at79) < 0.80)
        #expect(Matcher.titleSimilarity(base, at81) >= 0.80)
        #expect(pairs([expected(base, start: t0)], [found(at79, start: t0)]).pairs.isEmpty)
        #expect(pairs([expected(base, start: t0)], [found(at81, start: t0)]).pairs.count == 1)
    }

    @Test func theStartMayBeExactlyFiveMinutesAwayButNotMore() {
        #expect(pairs([expected("Team sync", start: t0)], [found("Team sync", start: t0.addingTimeInterval(300))]).pairs.count == 1)
        #expect(pairs([expected("Team sync", start: t0)], [found("Team sync", start: t0.addingTimeInterval(-300))]).pairs.count == 1)
        #expect(pairs([expected("Team sync", start: t0)], [found("Team sync", start: t0.addingTimeInterval(301))]).pairs.isEmpty)
    }

    @Test func tasksAreComparedOnTheDueDate() {
        #expect(pairs([expected("Send the report", kind: "task", due: t0)], [found("Send the report", kind: "task", due: t0)]).pairs.count == 1)
        #expect(pairs([expected("Send the report", kind: "task", due: t0)], [found("Send the report", kind: "task", due: t0.addingTimeInterval(86_400))]).pairs.isEmpty)
    }

    @Test func aDifferentKindNeverMatches() {
        #expect(pairs([expected("Report", kind: "task", due: t0)], [found("Report", kind: "deadline", due: t0)]).pairs.isEmpty)
    }

    @Test func twoSimilarFoundItemsForOneExpectedGiveOneMatchAndOneUnexpected() {
        let result = pairs([expected("Team sync", start: t0)],
                           [found("Team sync meeting", start: t0.addingTimeInterval(120)), found("Team sync", start: t0.addingTimeInterval(240))])
        #expect(result.pairs.count == 1 && result.pairs[0].foundIndex == 1)        // the exact title wins
        #expect(result.unmatchedFound == [0] && result.unmatchedExpected.isEmpty)
    }

    @Test func whenTitlesTieTheCloserTimeWins() {
        let result = pairs([expected("Team sync", start: t0)],
                           [found("Team sync", start: t0.addingTimeInterval(240)), found("Team sync", start: t0.addingTimeInterval(60))])
        #expect(result.pairs[0].foundIndex == 1)
    }

    @Test func eachFoundItemMatchesAtMostOneExpected() {
        let result = pairs([expected("Design review", start: t0), expected("Design review", start: t0.addingTimeInterval(120))],
                           [found("Design review", start: t0)])
        #expect(result.pairs.count == 1 && result.unmatchedExpected.count == 1)
    }

    @Test func allDayItemsMatchOnTheDate() {
        let midnight = Date(timeIntervalSince1970: 1_791_936_000)
        #expect(pairs([expected("Holiday", start: midnight, allDay: true)], [found("Holiday", start: midnight.addingTimeInterval(3600), allDay: true)]).pairs.count == 1)
        #expect(pairs([expected("Holiday", start: midnight, allDay: true)], [found("Holiday", start: midnight.addingTimeInterval(86_400), allDay: true)]).pairs.isEmpty)
    }

    @Test func itemsWithoutADateMatchOnKindAndTitleAlone() {
        #expect(pairs([expected("Call the bank", kind: "task")], [found("Call the bank", kind: "task")]).pairs.count == 1)
    }

    @Test func thresholdsArePublished() {
        #expect(MatchThresholds.standard.titleSimilarity == 0.80 && MatchThresholds.standard.minutes == 5)
    }
}
