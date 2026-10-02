import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Applying chosen differences of a trial, undoing them, and what never changes (spec 008, US3).
@Suite struct TrialApplyTests {
    private let clock = Date(timeIntervalSince1970: 1_800_200_000)

    private struct Rig {
        let f: ReconcileFixture
        let reconciler: Reconciler
        let store: TrialStore
        let comparison: TrialComparison
        let applier: TrialApplier
        let operations: ItemOperations
    }

    private func makeRig() throws -> Rig {
        let f = try ReconcileFixture()
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let store = TrialStore(database: f.database, paths: f.base.paths)
        return Rig(f: f, reconciler: reconciler, store: store, comparison: TrialComparison(database: f.database, reconciler: reconciler, store: store),
                   applier: TrialApplier(database: f.database, reconciler: reconciler, store: store, now: { Date(timeIntervalSince1970: 1_800_200_000) }),
                   operations: ItemOperations(database: f.database, reconciler: reconciler, now: { Date(timeIntervalSince1970: 1_800_200_000) }))
    }

    private func live(_ rig: Rig, _ findings: [Finding]) async throws {
        try rig.f.save(findings)
        let summary = await rig.reconciler.reconcile(imageID: rig.f.base.imageID)
        #expect(summary.error == nil)
    }

    @discardableResult
    private func trial(_ rig: Rig, _ findings: [Finding]) throws -> TrialRecord {
        let trial = try rig.store.create(model: "other", promptVersion: "p", think: "off", now: clock)
        let result = AnalysisResult(lines: [], classification: ClassificationResult(kind: .email, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: ""),
                                    findings: findings, timezone: TimeZone(identifier: "UTC")!, model: "other", pictureLongEdge: 2048)
        try rig.store.saveProposal(trialID: trial.id, imageID: rig.f.base.imageID, result: result, durationMs: 1, at: clock)
        return trial
    }

    private func item(_ rig: Rig, _ title: String) throws -> Item {
        try #require(try rig.f.read { db in try String.fetchOne(db, sql: "SELECT id FROM items WHERE title = ?", arguments: [title]) }.flatMap { id in try ItemStore(database: rig.f.database).item(id: id) })
    }

    private func report(_ rig: Rig, _ trial: TrialRecord) async throws -> TrialReport { try await rig.comparison.report(trialID: trial.id) }

    @Test func applyingAChangeUpdatesThatItemThroughTheUsualRecomputeAndLogsOneOperation() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30)), rig.f.finding("Gym", start: ReconcileFixture.minutes(300))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60), place: "Room 4"), rig.f.finding("Gym", start: ReconcileFixture.minutes(300))])
        let r = try await report(rig, t)
        let change = try #require(r.differences.first { $0.kind == .changed })
        let gymBefore = try item(rig, "Gym")
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: [change.id])
        #expect(result.applied == [change.id] && result.skipped.isEmpty && result.operationID != nil)
        let standup = try item(rig, "Daily standup")
        #expect(standup.end == ReconcileFixture.minutes(60) && standup.place == "Room 4")
        #expect(try item(rig, "Gym") == gymBefore)                                             // nothing else moved
        let ops = try OperationLog(database: rig.f.database).recent()
        #expect(ops.first?.kind == "apply_trial" && ops.first?.byUser == true)
        let sightings = try rig.f.count("sightings")
        #expect(sightings == 2)                                                               // the old sighting gave way, not duplicated
    }

    @Test func applyingANewDifferenceCreatesTheItemWithItsSightingAndEvidenceTrail() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup")])
        let t = try trial(rig, [rig.f.finding("Daily standup"), rig.f.finding("Dentist", start: ReconcileFixture.minutes(120), confidence: 0.5)])
        let d = try #require(try await report(rig, t).differences.first { $0.kind == .new })
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id])
        #expect(result.applied == [d.id])
        let dentist = try item(rig, "Dentist")
        #expect(dentist.needsReview && dentist.start == ReconcileFixture.minutes(120))      // the Inbox rules ran (confidence 0.5)
        let findingIDs = try rig.f.read { try String.fetchAll($0, sql: "SELECT finding_id FROM sightings WHERE item_id = ?", arguments: [dentist.id]) }
        #expect(findingIDs == [d.id])
    }

    @Test func applyingTwiceChangesNothingTheSecondTime() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60)), rig.f.finding("Dentist", start: ReconcileFixture.minutes(120))])
        let ids = try await report(rig, t).differences.filter(\.applicable).map(\.id)
        _ = try await rig.applier.apply(trialID: t.id, differenceIDs: ids)
        let after = try rig.f.snapshot(), ops = try rig.f.count("reconcile_ops")
        let second = try await rig.applier.apply(trialID: t.id, differenceIDs: ids)
        #expect(second.operationID == nil && second.applied.isEmpty && second.skipped.count == 2)
        #expect(try rig.f.snapshot() == after)
        #expect(try rig.f.count("reconcile_ops") == ops)
        let again = try await report(rig, t)
        #expect(again.totals.applied == 2 && again.differences.allSatisfy { !$0.applicable })
    }

    @Test func aProtectedDifferenceIsSkippedWithAReasonAndTheUsersValueStays() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let standup = try item(rig, "Daily standup")
        _ = try rig.operations.edit(standup.id, field: .end, value: .date(ReconcileFixture.minutes(45)))
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await report(rig, t).differences.first)
        let before = try rig.f.snapshot()
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id])
        #expect(result.applied.isEmpty && result.operationID == nil && result.skipped.first?.reason == "You set end")
        #expect(try rig.f.snapshot() == before)
        #expect(try item(rig, "Daily standup").end == ReconcileFixture.minutes(45))
    }

    @Test func anItemTheTrialDidNotFindIsNeverRemoved() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup"), rig.f.finding("Gym", start: ReconcileFixture.minutes(300))])
        let t = try trial(rig, [rig.f.finding("Daily standup")])
        let missing = try #require(try await report(rig, t).differences.first { $0.kind == .notFound })
        let before = try rig.f.snapshot()
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: [missing.id])
        #expect(result.applied.isEmpty && result.skipped.count == 1)
        #expect(try rig.f.snapshot() == before)
    }

    @Test func undoPutsBackEverythingTheApplyChangedExactly() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30)), rig.f.finding("Gym", start: ReconcileFixture.minutes(300), confidence: 0.5)])
        let before = try rig.f.snapshot()
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60), place: "Room 4"), rig.f.finding("Gym", start: ReconcileFixture.minutes(300), confidence: 0.5),
                                rig.f.finding("Dentist", start: ReconcileFixture.minutes(120))])
        let ids = try await report(rig, t).differences.filter(\.applicable).map(\.id)
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: ids)
        let op = try #require(result.operationID)
        #expect(try rig.f.snapshot() != before)
        let undone = try await rig.operations.undo(op)
        guard case .undone = undone else { Issue.record("expected undone, got \(undone)"); return }
        let after = try rig.f.snapshot()
        #expect(after == before, "\(ReconcileFixture.difference(before, after))")
        // The apply can be made again after an undo, and the undo can be undone.
        let again = try await rig.applier.apply(trialID: t.id, differenceIDs: ids)
        #expect(again.applied.count == ids.count)
    }

    @Test func undoIsRefusedForItemsThatChangedAfterTheApply() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await report(rig, t).differences.first)
        let op = try #require(try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id]).operationID)
        _ = try rig.operations.edit(try item(rig, "Daily standup").id, field: .title, value: .string("Renamed"))
        let result = try await rig.operations.undo(op)
        if case .undone = result { Issue.record("a later edit must stop the undo") }
        #expect(try item(rig, "Renamed").end == ReconcileFixture.minutes(60))                // left as the user last had it
    }

    @Test func applyingOneReadingKeepsTheCapturesOtherReadingOfTheSameItemAndUndoRestoresBoth() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        // The capture shows the event twice (two windows): two sightings of one item.
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30)), rig.f.finding("Daily standup.", end: ReconcileFixture.minutes(30))])
        let before = try rig.f.snapshot()
        let sightingsBefore = try rig.f.count("sightings"), items = try rig.f.count("items")
        #expect(sightingsBefore == 2 && items == 1)
        let proposals = [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60)), rig.f.finding("Daily standup.", end: ReconcileFixture.minutes(30))]
        let t = try trial(rig, proposals)
        let all = try await report(rig, t).differences
        let changed = try #require(all.first { $0.kind == .changed && $0.title == "Daily standup" })
        let result = try await rig.applier.apply(trialID: t.id, differenceIDs: [changed.id])
        #expect(result.applied == [changed.id])
        let during = try rig.f.read { try String.fetchAll($0, sql: "SELECT title FROM sightings ORDER BY title") }
        #expect(during.count == 2 && during.contains("Daily standup."))                 // the other reading stayed, nothing was lost
        let undone = try await rig.operations.undo(try #require(result.operationID))
        guard case .undone = undone else { Issue.record("expected undone, got \(undone)"); return }
        let after = try rig.f.snapshot()
        #expect(after == before, "\(ReconcileFixture.difference(before, after))")
    }

    @Test func undoRestoresEveryReadingEvenWhenTheApplyReplacedTwoOfOneCapture() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30)), rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let before = try rig.f.snapshot()
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60)), rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let ids = try await report(rig, t).differences.filter(\.applicable).map(\.id)
        #expect(ids.count == 2)
        let op = try #require(try await rig.applier.apply(trialID: t.id, differenceIDs: ids).operationID)
        #expect(try rig.f.count("sightings") == 2)
        let undone = try await rig.operations.undo(op)
        guard case .undone = undone else { Issue.record("expected undone, got \(undone)"); return }
        let after = try rig.f.snapshot()
        #expect(after == before, "\(ReconcileFixture.difference(before, after))")
    }

    @Test func undoDoesNotCountTheSameReadingTwiceWhenTheCaptureWasReadAgainMeanwhile() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await report(rig, t).differences.first)
        let op = try #require(try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id]).operationID)
        _ = await rig.reconciler.reconcile(imageID: rig.f.base.imageID)               // a reanalysis, a context change or the library re-read
        let sightings = try rig.f.count("sightings")
        let result = try await rig.operations.undo(op)
        if case .undone = result { Issue.record("the old sighting must not be put back next to the new one") }
        let after = try rig.f.count("sightings"), perItem = try rig.f.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM sightings GROUP BY item_id") }
        #expect(after == sightings && perItem.allSatisfy { $0 == 1 })
    }

    private final class RecordingEvidence: ImageEvidenceWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var images: [String] { lock.withLock { seen } }
        func write(imageID: String) async -> Int { lock.withLock { seen.append(imageID) }; return 0 }
    }

    @Test func cutOutsAreMadeAgainAfterAnApplyAndAfterItsUndo() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let recording = RecordingEvidence()
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let store = TrialStore(database: f.database, paths: f.base.paths)
        let applier = TrialApplier(database: f.database, reconciler: reconciler, store: store, evidence: recording, now: { Date(timeIntervalSince1970: 1_800_200_000) })
        let operations = ItemOperations(database: f.database, reconciler: reconciler, evidence: recording, now: { Date(timeIntervalSince1970: 1_800_200_000) })
        try f.save([f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        _ = await reconciler.reconcile(imageID: f.base.imageID)
        let trial = try store.create(model: "other", promptVersion: "p", think: "off", now: clock)
        let result = AnalysisResult(lines: [], classification: ClassificationResult(kind: .email, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: ""),
                                    findings: [f.finding("Daily standup", end: ReconcileFixture.minutes(60))], timezone: TimeZone(identifier: "UTC")!, model: "other", pictureLongEdge: 2048)
        try store.saveProposal(trialID: trial.id, imageID: f.base.imageID, result: result, durationMs: 1, at: clock)
        let d = try #require(try await TrialComparison(database: f.database, reconciler: reconciler, store: store).report(trialID: trial.id).differences.first)
        let op = try #require(try await applier.apply(trialID: trial.id, differenceIDs: [d.id]).operationID)
        #expect(recording.images == [f.base.imageID])
        _ = try await operations.undo(op)
        #expect(recording.images == [f.base.imageID, f.base.imageID])
    }

    @Test func theOperationShowsInTheItemsHistoryAndIsWhatUndoLastWouldUndo() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await report(rig, t).differences.first)
        let op = try #require(try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id]).operationID)
        let history = try OperationLog(database: rig.f.database).ops(forItem: try item(rig, "Daily standup").id)
        #expect(history.first?.id == op && ItemListModel.operationText(history.first!.kind) == "Applied a reprocessing trial")
        let recent = try OperationLog(database: rig.f.database).recent()
        #expect(ItemListModel.undoTarget(in: recent)?.id == op)
        let record = try #require(try OperationLog(database: rig.f.database).operation(id: op))
        #expect(record.detail["model"]?.asString == "other" && record.detail["trial"]?.asString == t.id)
    }

    @Test func deletingTheTrialLeavesTheItemsAndTheAuditTrail() async throws {
        let rig = try makeRig(); defer { rig.f.cleanUp() }
        try await live(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(30))])
        let t = try trial(rig, [rig.f.finding("Daily standup", end: ReconcileFixture.minutes(60))])
        let d = try #require(try await report(rig, t).differences.first)
        _ = try await rig.applier.apply(trialID: t.id, differenceIDs: [d.id])
        let before = try rig.f.snapshot(), ops = try rig.f.count("reconcile_ops")
        try rig.store.delete(t.id)
        #expect(try rig.f.snapshot() == before && rig.f.count("reconcile_ops") == ops)
        // The audit trail still says which trial it was: model, prompt, when it started and how many captures it had read.
        let entry = try #require(try rig.store.history().first)
        #expect(entry.model == "other" && entry.promptVersion == "p" && entry.captures == 1 && entry.applied == 1)
        #expect(entry.trialStarted.map { abs($0.timeIntervalSince(clock)) < 1 } == true)
    }
}
