import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// What a trial would change, compared with the items as they are (spec 008, US2).
@Suite struct TrialComparisonTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)
    private let nine = ReconcileFixture.nine

    private struct Rig {
        let f: ReconcileFixture
        let reconciler: Reconciler
        let store: TrialStore
        let comparison: TrialComparison
        let operations: ItemOperations
    }

    private func makeRig() throws -> Rig {
        let f = try ReconcileFixture()
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let store = TrialStore(database: f.database, paths: f.base.paths)
        return Rig(f: f, reconciler: reconciler, store: store, comparison: TrialComparison(database: f.database, reconciler: reconciler, store: store),
                   operations: ItemOperations(database: f.database, reconciler: reconciler, now: { Date(timeIntervalSince1970: 1_800_200_000) }))
    }

    private func live(_ rig: Rig, _ findings: [Finding]) async throws {
        try rig.f.save(findings)
        let summary = await rig.reconciler.reconcile(imageID: rig.f.base.imageID)
        #expect(summary.error == nil)
    }

    @discardableResult
    private func trial(_ rig: Rig, _ findings: [Finding], model: String = "other") throws -> TrialRecord {
        let trial = try rig.store.create(model: model, promptVersion: "p", think: "off", now: clock)
        let result = AnalysisResult(lines: [], classification: ClassificationResult(kind: .email, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: ""),
                                    findings: findings, timezone: TimeZone(identifier: "UTC")!, model: model, pictureLongEdge: 2048)
        try rig.store.saveProposal(trialID: trial.id, imageID: rig.f.base.imageID, result: result, durationMs: 1, at: clock)
        return trial
    }

    private func itemID(_ rig: Rig, _ title: String) throws -> String {
        try rig.f.read { try String.fetchOne($0, sql: "SELECT id FROM items WHERE title = ?", arguments: [title])! }
    }

    @Test func aSameReadingIsUnchanged() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let report = try await rig.comparison.report(trialID: t.id)
        #expect(report.differences.map(\.kind) == [.unchanged] && report.totals.unchanged == 1 && report.totals.new == 0)
    }

    @Test func aTitleThatOnlyDiffersInEncodingOrSpacesIsNotAChange() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Revisi\u{00F3}n Servidor IA")])                              // composed accent
        let t = try trial(rig, [rig.f.finding("Revisio\u{0301}n\u{00A0}Servidor  IA ")])               // decomposed accent, no-break and double spaces
        let report = try await rig.comparison.report(trialID: t.id)
        #expect(report.differences.map(\.kind) == [.unchanged])
        #expect(TrialComparison.sameText("Revisi\u{00F3}n\u{200B} Servidor\u{200E} IA", "Revisi\u{00F3}n Servidor IA"))      // zero-width space and a direction mark
        #expect(TrialComparison.sameText("Sala", "sala") == false && TrialComparison.sameText("Caf\u{00E9}", "Cafe") == false)
    }

    @Test func aDifferentEndAndAPlaceAreAChangeWithCurrentAndProposedValues() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60), place: "Room 4")])
        let d = try #require(try await rig.comparison.report(trialID: t.id).differences.first)
        #expect(d.kind == .changed && d.applicable && d.protection == nil)
        #expect(d.changes.map(\.field) == [.end, .place])
        #expect(d.changes[0].current == "Wed 14 Oct 07:30" && d.changes[0].proposed == "Wed 14 Oct 08:00" && d.changes[1].current == "none" && d.changes[1].proposed == "Room 4")
    }

    @Test func anExtraFindingIsNewAndAMissingOneIsNotFoundNeverRemoved() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup"), rig.f.finding("Gym", start: ReconcileFixture.minutes(300))])
        let t = try trial(rig, [rig.f.finding("Daily standup"), rig.f.finding("Dentist", start: ReconcileFixture.minutes(120))])
        let report = try await rig.comparison.report(trialID: t.id)
        let byKind = Dictionary(grouping: report.differences, by: \.kind)
        #expect(byKind[.new]?.map(\.title) == ["Dentist"] && byKind[.notFound]?.map(\.title) == ["Gym"] && byKind[.unchanged]?.map(\.title) == ["Daily standup"])
        #expect(byKind[.notFound]?.first?.applicable == false)
        #expect(report.totals.new == 1 && report.totals.notFound == 1 && report.totals.unchanged == 1)
    }

    @Test func aFieldTheUserSetIsProtectedAsLocked() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let id = try itemID(rig, "Daily standup")
        _ = try rig.operations.edit(id, field: .end, value: .date(ReconcileFixture.minutes(45)))
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await rig.comparison.report(trialID: t.id).differences.first)
        #expect(d.kind == .changed && d.protection == .locked([.end]) && !d.applicable)
    }

    @Test func anItemTheUserApprovedIsProtected() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30), confidence: 0.5)])
        _ = try rig.operations.approve(try itemID(rig, "Daily standup"))
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60), confidence: 0.5)])
        let report = try await rig.comparison.report(trialID: t.id)
        #expect(report.differences.first?.protection == .approved && report.totals.protected == 1)
    }

    @Test func aDismissedItemIsNeverProposedAsNewAndIsProtected() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        _ = try rig.operations.dismiss(try itemID(rig, "Daily standup"))
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let report = try await rig.comparison.report(trialID: t.id)
        #expect(report.differences.map(\.kind) == [.changed] && report.differences.first?.protection == .dismissed && report.totals.new == 0)
    }

    @Test func totalsAddUpAndLowConfidenceProposalsAreFlaggedForReview() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(30)), rig.f.finding("B", start: ReconcileFixture.minutes(200)), rig.f.finding("C", start: ReconcileFixture.minutes(400))])
        let t = try trial(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(90)), rig.f.finding("B", start: ReconcileFixture.minutes(200)),
                                rig.f.finding("D", start: ReconcileFixture.minutes(600), confidence: 0.4)])
        let report = try await rig.comparison.report(trialID: t.id)
        let totals = report.totals
        #expect(totals.changed == 1 && totals.unchanged == 1 && totals.new == 1 && totals.notFound == 1 && totals.review == 1)
        #expect(totals.new + totals.changed + totals.unchanged + totals.notFound == report.differences.count)
    }

    @Test func comparingASecondTrialShowsWhereTheTwoDiffer() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("A")])
        let first = try trial(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(30)), rig.f.finding("Only first", start: ReconcileFixture.minutes(100))], model: "m1")
        try rig.store.cancel(first.id, now: clock)
        let second = try trial(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(60)), rig.f.finding("Only second", start: ReconcileFixture.minutes(150))], model: "m2")
        let pairs = try rig.comparison.between(first.id, second.id)
        #expect(pairs.contains { $0.kind == .differs && $0.title == "A" && $0.changes.map(\.field) == [.end] })
        #expect(pairs.contains { $0.kind == .onlyInFirst && $0.title == "Only first" } && pairs.contains { $0.kind == .onlyInSecond && $0.title == "Only second" })
    }

    @Test func comparingChangesNothing() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("A", end: ReconcileFixture.minutes(60)), rig.f.finding("New", start: ReconcileFixture.minutes(100))])
        let before = try rig.f.snapshot()
        _ = try await rig.comparison.report(trialID: t.id)
        let after = try rig.f.snapshot()
        #expect(after == before)
    }
}
