import Foundation
import Testing
@testable import MemorriCore

@Suite struct MetricsTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_986_400)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func golden(_ name: String = "case", kind: String = "calendar_week", origin: GoldenOrigin = .synthetic,
                        findings: [ExpectedFinding] = [], tags: [ExpectedTag]? = nil, context: String? = nil,
                        lines: [ExpectedLine]? = nil) -> GoldenCase {
        let meta = GoldenMeta(capturedAt: t0, macTimezone: "UTC", context: nil, windows: [], displaySize: [100, 100], scale: 1, origin: origin)
        return GoldenCase(name: name, folder: URL(fileURLWithPath: "/tmp/\(name)"), meta: meta,
                          expected: GoldenExpected(screenKind: kind, tags: tags, context: context, lines: lines, findings: findings))
    }
    private func result(kind: String = "calendar_week", findings: [FoundFinding] = [], tags: [FoundTag] = [],
                        context: String? = nil, lines: [FoundLine] = []) -> CaseResult {
        CaseResult(kind: kind, findings: findings, tags: tags, contextName: context, lines: lines, seconds: 1, steps: [])
    }
    private func score(_ g: GoldenCase, _ r: CaseResult) -> CaseScore { Metrics.score(g, r) }

    @Test func aPerfectCaseScoresOneEverywhere() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Team sync", start: t0, end: at(90), allDay: false, people: ["Anna"], place: "Room 1", inferred: ["end"])])
        let r = result(findings: [FoundFinding(kind: "appointment", title: "Team sync", start: t0, end: at(90), allDay: false, people: ["anna"], place: "room 1", inferred: ["end"])])
        let s = score(g, r)
        #expect(s.precision == 1 && s.recall == 1 && s.fieldAccuracy == 1)
        #expect(s.missed.isEmpty && s.unexpected.isEmpty)
    }

    @Test func aMissingExpectedFindingLowersRecallAndIsListed() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Team sync", start: t0),
                                  ExpectedFinding(kind: "appointment", title: "Design review", start: at(120))])
        let s = score(g, result(findings: [FoundFinding(kind: "appointment", title: "Team sync", start: t0)]))
        #expect(s.recall == 0.5 && s.precision == 1)
        #expect(s.missed.map(\.title) == ["Design review"])
    }

    @Test func anExtraFoundFindingLowersPrecisionAndNamesTheClosestExpected() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Team sync", start: t0)])
        let s = score(g, result(findings: [FoundFinding(kind: "appointment", title: "Team sync", start: t0),
                                           FoundFinding(kind: "appointment", title: "Team synk at noon", start: at(300))]))
        #expect(s.precision == 0.5 && s.recall == 1)
        #expect(s.unexpected.count == 1 && s.unexpected[0].found.title == "Team synk at noon")
        #expect(s.unexpected[0].closestExpectedTitle == "Team sync")
    }

    @Test func fieldAccuracyCountsDatesFlagsPeoplePlaceAndAllDayOnMatchedFindingsOnly() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Team sync", start: t0, end: at(90), people: ["Anna", "Bob"], place: "Room 1", inferred: ["end"]),
                                  ExpectedFinding(kind: "appointment", title: "Never found", start: at(600))])
        // found: end 30 minutes short (value wrong), people right as a set, place right, end flagged, start not flagged
        let r = result(findings: [FoundFinding(kind: "appointment", title: "Team sync", start: t0, end: at(60), people: ["BOB", "anna"], place: "ROOM 1", inferred: ["end"])])
        let s = score(g, r)
        // compared: start, end, start flag, end flag, people, place  -> 6, equal: all but end
        #expect(s.comparedFields == 6 && s.equalFields == 5)
        #expect(abs((s.fieldAccuracy ?? 0) - 5.0 / 6.0) < 1e-9)
    }

    @Test func aWronglyFlaggedInferredFieldCountsAsAWrongField() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Team sync", start: t0, end: at(60))])
        let s = score(g, result(findings: [FoundFinding(kind: "appointment", title: "Team sync", start: t0, end: at(60), inferred: ["end"])]))
        #expect(s.comparedFields == 4 && s.equalFields == 3)
    }

    @Test func allDayIsComparedOnlyWhenEitherSideSaysSo() {
        let g = golden(findings: [ExpectedFinding(kind: "appointment", title: "Holiday", start: t0, allDay: true)])
        let s = score(g, result(findings: [FoundFinding(kind: "appointment", title: "Holiday", start: t0, allDay: false)]))
        #expect(s.comparedFields == 3 && s.equalFields == 2)       // start, start flag, allDay (wrong)
    }

    @Test func nothingFoundAndNothingExpectedScoresOne() {
        let s = score(golden(), result())
        #expect(s.precision == 1 && s.recall == 1 && s.fieldAccuracy == nil)
    }

    @Test func nothingFoundWhenSomethingIsExpectedIsRecallZeroAndPrecisionOne() {
        let s = score(golden(findings: [ExpectedFinding(kind: "task", title: "Report", due: t0)]), result())
        #expect(s.recall == 0 && s.precision == 1)
    }

    @Test func classificationIsCorrectWhenTheKindEqualsTheExpectedOne() {
        #expect(score(golden(kind: "email"), result(kind: "email")).kindCorrect)
        #expect(!score(golden(kind: "email"), result(kind: "chat")).kindCorrect)
    }

    @Test func tagsAreScoredPerKeyWithWrongAndMissingCounts() {
        let g = golden(tags: [ExpectedTag(key: "application", value: "Outlook"), ExpectedTag(key: "clock_style", value: "24h"), ExpectedTag(key: "theme", value: "dark")])
        let r = result(tags: [FoundTag(key: "application", value: "outlook", confidence: 0.9),
                              FoundTag(key: "clock_style", value: "12h", confidence: 0.9)])
        let s = score(g, r)
        #expect(s.tagResults["application"] == TagScore(correct: 1, wrong: 0, missing: 0))
        #expect(s.tagResults["clock_style"] == TagScore(correct: 0, wrong: 1, missing: 0))
        #expect(s.tagResults["theme"] == TagScore(correct: 0, wrong: 0, missing: 1))
        #expect(s.wrongHighConfidenceTags == 1)
    }

    @Test func aWrongTagWithLowConfidenceIsNotCountedAsWrongHighConfidence() {
        let g = golden(tags: [ExpectedTag(key: "theme", value: "dark")])
        let s = score(g, result(tags: [FoundTag(key: "theme", value: "light", confidence: 0.4)]))
        #expect(s.tagResults["theme"]?.wrong == 1 && s.wrongHighConfidenceTags == 0)
    }

    @Test func contextAccuracyIsScoredOnlyWhenOneIsExpected() {
        #expect(score(golden(context: "Customer A"), result(context: "customer a")).contextCorrect == true)
        #expect(score(golden(context: "Customer A"), result(context: nil)).contextCorrect == false)
        #expect(score(golden(), result(context: "Customer A")).contextCorrect == nil)
    }

    @Test func readingIsScoredByExactTextAndBoxOverlap() {
        let g = golden(lines: [ExpectedLine(text: "Team sync", box: [10, 10, 100, 30]), ExpectedLine(text: "Mon 12", box: [200, 10, 80, 30]),
                               ExpectedLine(text: "Missing", box: [0, 100, 50, 20])])
        let r = result(lines: [FoundLine(text: "Team sync", box: [12, 12, 98, 28]), FoundLine(text: "Mon 12", box: [500, 500, 80, 30])])
        let s = score(g, r)
        #expect(s.ocrExact == 2 && s.ocrExpected == 3)
        #expect(s.ocrOverlap == 1 && s.ocrBoxed == 3)
    }

    @Test func aTitleThatIsNotInTheCitedTextIsADisagreement() {
        let g = golden(findings: [ExpectedFinding(kind: "task", title: "Send the report", due: t0)])
        let ok = FoundFinding(kind: "task", title: "Send the report", due: t0, citedText: "Anna needs: send the report by Friday")
        let bad = FoundFinding(kind: "task", title: "Buy milk", due: t0, citedText: "Anna needs the report by Friday")
        #expect(score(g, result(findings: [ok])).disagreements.isEmpty)
        #expect(score(g, result(findings: [bad])).disagreements.map(\.title) == ["Buy milk"])
    }

    @Test func summariesAddUpAcrossCasesByKindOriginAndConfidence() {
        let g1 = golden("a", kind: "email", origin: .synthetic, findings: [ExpectedFinding(kind: "task", title: "Report", due: t0)])
        let g2 = golden("b", kind: "chat", origin: .local, findings: [ExpectedFinding(kind: "task", title: "Deck", due: t0), ExpectedFinding(kind: "task", title: "Demo", due: t0)])
        let s1 = score(g1, result(kind: "email", findings: [FoundFinding(kind: "task", title: "Report", due: t0, confidence: 0.9)]))
        let s2 = score(g2, result(kind: "email", findings: [FoundFinding(kind: "task", title: "Deck", due: t0, confidence: 0.4),
                                                            FoundFinding(kind: "task", title: "Noise", due: t0, confidence: 0.7)]))
        let summary = Metrics.summarise([(g1, s1), (g2, s2)])
        #expect(summary.overall.cases == 2)
        #expect(summary.overall.precision == 2.0 / 3.0)                 // 2 matched of 3 found
        #expect(summary.overall.recall == 2.0 / 3.0)                    // 2 matched of 3 expected
        #expect(summary.overall.classificationAccuracy == 0.5)
        #expect(summary.byKind["email"]?.cases == 1 && summary.byKind["chat"]?.cases == 1)
        #expect(summary.byOrigin["synthetic"]?.precision == 1 && summary.byOrigin["local"]?.precision == 0.5)
        #expect(summary.byConfidence["high"] == ConfidenceBandScore(found: 1, matched: 1))
        #expect(summary.byConfidence["low"] == ConfidenceBandScore(found: 1, matched: 1))
        #expect(summary.byConfidence["mid"] == ConfidenceBandScore(found: 1, matched: 0))
    }

    @Test func confidenceBandsSplitAtPointSixAndPointEightFive() {
        #expect(Metrics.band(forConfidence: 0.59) == "low")
        #expect(Metrics.band(forConfidence: 0.6) == "mid")
        #expect(Metrics.band(forConfidence: 0.85) == "mid")
        #expect(Metrics.band(forConfidence: 0.851) == "high")
    }
}
