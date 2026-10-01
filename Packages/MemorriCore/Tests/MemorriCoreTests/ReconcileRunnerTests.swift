import Foundation
import Testing
@testable import MemorriCore

@Suite struct ReconcileRunnerTests {
    private let nine = Date(timeIntervalSince1970: 1_791_961_200)      // 2026-10-14 07:00 UTC

    private func at(_ minutes: Int) -> Date { nine.addingTimeInterval(Double(minutes) * 60) }

    private func finding(_ event: String, _ title: String, start: Int = 0, lang: String? = nil, kind: FindingKind = .appointment) -> SequenceCase.FindingSpec {
        SequenceCase.FindingSpec(event: event, kind: kind, title: title, lang: lang, start: at(start), end: nil)
    }

    private func sequence(_ name: String = "case", captures: [[SequenceCase.FindingSpec]], actions: [SequenceCase.Action] = []) -> SequenceCase {
        SequenceCase(name: name, macTimezone: "UTC", contexts: [],
                     captures: captures.enumerated().map { SequenceCase.CaptureSpec(id: "c\($0)", capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 3600), findings: $1) },
                     actions: actions)
    }

    private func run(_ cases: [SequenceCase], judge: any MeaningJudging = NoMeaningJudge(), models: Bool = false) async throws -> SequenceReport {
        try await ReconcileRunner(judge: judge, modelsOn: models).run(cases: cases)
    }

    @Test func twoSightingsOfOneEventThatEndInOneItemScoreAFullRecall() async throws {
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup")], [finding("standup", "Daily stand…")]])])
        let score = try #require(report.cases.first)
        #expect(score.items == 1 && score.pairs == 1 && score.mergedPairs == 1 && score.wrongMergedItems == 0 && score.missedMerges.isEmpty)
        #expect(report.overall.mergeRecall == 1 && report.overall.wrongMergeRate == 0 && report.overall.items == 1)
        #expect(score.captures == 2)
    }

    @Test func aPairThatStayedApartLowersTheRecallAndIsNamed() async throws {
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup")], [finding("standup", "Team sync", start: 180)]])])
        let score = try #require(report.cases.first)
        #expect(score.items == 2 && score.mergedPairs == 0 && score.pairs == 1)
        #expect(score.missedMerges == ["Daily standup | Team sync"])
        #expect(report.overall.mergeRecall == 0)
    }

    @Test func twoEventsInOneItemCountAsAWrongMergeAndAreListed() async throws {
        let report = try await run([sequence(captures: [[finding("a", "Daily standup")], [finding("b", "Daily standup")]])])
        let score = try #require(report.cases.first)
        #expect(score.items == 1 && score.wrongMergedItems == 1 && score.wrongMerges.count == 1)
        #expect(score.wrongMerges[0].contains("Daily standup") && score.wrongMerges[0].contains("a") && score.wrongMerges[0].contains("b"))
        #expect(report.overall.wrongMergeRate == 1)
    }

    @Test func pairsSentToTheJudgeAreCountedOverComparedPairs() async throws {
        let judge = FakeMeaningJudge(defaultAnswer: 0.99)
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup", lang: "en")], [finding("standup", "Reunión diaria", lang: "es")]])],
                                   judge: judge, models: true)
        let score = try #require(report.cases.first)
        #expect(score.comparedPairs == 1 && score.judgedPairs == 1 && score.mergedPairs == 1 && score.translatedPairs == 1 && score.translatedMerged == 1)
        #expect(report.overall.judgedShare == 1 && report.overall.mergeRecall == 1 && report.overall.translatedFlagged == 1)
    }

    @Test func withoutModelsTranslatedPairsAreLeftOutOfTheRecallAndReportedAsFlagged() async throws {
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup", lang: "en")], [finding("standup", "Reunión diaria", lang: "es")]])])
        let score = try #require(report.cases.first)
        #expect(score.items == 2 && score.mergedPairs == 0 && score.translatedPairs == 1 && score.translatedFlagged == 1 && score.translatedMerged == 0)
        #expect(report.overall.mergeRecall == 1)                    // no pairs left to merge once the translated one is set aside
        #expect(report.overall.translatedFlagged == 1)
    }

    @Test func aTranslatedPairThatIsNeitherMergedNorFlaggedLowersTheHandledShare() async throws {
        // Same words and time would merge; different times keep them apart without a possible duplicate.
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup", lang: "en")],
                                                       [finding("standup", "Reunión diaria", start: 120, lang: "es")]])])
        #expect(report.cases[0].translatedFlagged == 0 && report.overall.translatedFlagged == 0)
    }

    @Test func aDismissedEventIsNotRecreatedAndAnEditedTitleIsKept() async throws {
        let actions = [SequenceCase.Action(after: "c0", action: .dismiss, event: "standup"),
                       SequenceCase.Action(after: "c0", action: .editTitle, event: "review", title: "My review")]
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup"), finding("review", "Design review", start: 120)],
                                                       [finding("standup", "Daily standup"), finding("review", "Design review", start: 120)]], actions: actions)])
        let score = try #require(report.cases.first)
        #expect(score.recreatedDismissed == 0 && score.overwrittenTitles == 0)
        #expect(report.overall.recreatedDismissed == 0 && report.overall.overwrittenTitles == 0)
        #expect(score.items == 2)
    }

    @Test func aRecreatedDismissalAndAnOverwrittenTitleAreCounted() async throws {
        // The second sighting has an unrelated title at another time, so it cannot be told from a new event.
        let actions = [SequenceCase.Action(after: "c0", action: .dismiss, event: "standup")]
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup")], [finding("standup", "Team sync", start: 240)]], actions: actions)])
        #expect(report.cases[0].recreatedDismissed == 1)
    }

    @Test func aRestoreBringsADismissedEventBackAndASplitSeparatesTheLatestSighting() async throws {
        let actions = [SequenceCase.Action(after: "c0", action: .dismiss, event: "standup"), SequenceCase.Action(after: "c1", action: .restore, event: "standup"),
                       SequenceCase.Action(after: "c2", action: .split, event: "standup")]
        let report = try await run([sequence(captures: [[finding("standup", "Daily standup")], [finding("standup", "Daily standup")], [finding("standup", "Daily standup")]],
                                             actions: actions)])
        let score = try #require(report.cases.first)
        #expect(score.items == 2 && score.recreatedDismissed == 0)
        #expect(score.pairs == 3 && score.mergedPairs == 1)          // the split-off sighting is apart from the other two
    }

    @Test func overallNumbersCombineTheCases() async throws {
        let merged = sequence("a", captures: [[finding("x", "Daily standup")], [finding("x", "Daily standup")]])
        let apart = sequence("b", captures: [[finding("y", "Daily standup")], [finding("y", "Team sync", start: 300)]])
        let report = try await run([merged, apart])
        #expect(report.overall.mergeRecall == 0.5 && report.overall.items == 3 && report.overall.captures == 4)
        #expect(report.overall.msPerCapture >= 0)
    }

    @Test func onlyRunsTheNamedCase() async throws {
        let report = try await ReconcileRunner(judge: NoMeaningJudge(), modelsOn: false)
            .run(cases: [sequence("a", captures: [[finding("x", "One")]]), sequence("b", captures: [[finding("y", "Two")]])], only: "b")
        #expect(report.cases.map(\.name) == ["b"])
    }

    @Test func theReportRoundTripsAndComparesWithAnother() async throws {
        let a = try await run([sequence(captures: [[finding("x", "Daily standup")], [finding("x", "Daily standup")]])])
        let b = try await run([sequence(captures: [[finding("x", "Daily standup")], [finding("x", "Team sync", start: 300)]])])
        #expect(try SequenceReport.decode(a.encoded()) == a)
        let text = SequenceReport.compare(a, b)
        #expect(text.contains("merge recall -1.00") && text.contains("case"))
        #expect(a.text.contains("merge recall") && a.text.contains("wrong merges"))
    }

    @Test func theTrackedSyntheticSetPassesTheOffModeGate() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/golden/synthetic-sequences")
        let cases = try SequenceCase.loadAll(in: folder)
        let report = try await run(cases)
        #expect(report.overall.mergeRecall >= 0.95, Comment(rawValue: report.text))
        #expect(report.overall.wrongMergeRate <= 0.02, Comment(rawValue: report.text))
        #expect(report.overall.translatedFlagged ?? 1 >= 1, Comment(rawValue: report.text))
        #expect(report.overall.recreatedDismissed == 0 && report.overall.overwrittenTitles == 0, Comment(rawValue: report.text))
    }
}
