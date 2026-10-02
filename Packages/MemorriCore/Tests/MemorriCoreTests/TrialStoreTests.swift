import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Trials: creating, cancelling, resuming and deleting them, and what they keep apart from the library (spec 008, US1).
@Suite struct TrialStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_500_000)

    private func store(_ f: ReconcileFixture) -> TrialStore { TrialStore(database: f.database, paths: f.base.paths) }

    private func addKept(_ f: ReconcileFixture, at date: Date) throws -> String {
        let id = try f.addPicture(at: date)
        let image = try f.read { try Row.fetchOne($0, sql: "SELECT full_path, model_path FROM capture_images WHERE id = ?", arguments: [id])! }
        for column in ["full_path", "model_path"] {
            let url = f.base.paths.root.appendingPathComponent(image[column] as String)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeHEICData(width: 40, height: 20).write(to: url)
        }
        return id
    }

    private func jobs(_ f: ReconcileFixture) throws -> [AnalysisJobRecord] {
        try f.read { try AnalysisJobRecord.fetchAll($0, sql: "SELECT * FROM analysis_jobs WHERE kind = 'trial' ORDER BY created_at, id") }
    }

    @Test func aTrialQueuesOneLowPriorityJobPerKeptCaptureNewestFirstAndSkipsTheRest() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let second = try addKept(f, at: Date(timeIntervalSince1970: 1_800_100_000))
        let gone = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_200_000))        // no files on disk
        for id in [f.base.imageID, second, gone] { try f.save([f.finding("Standup")], imageID: id) }
        let trial = try store(f).create(model: "other:model", promptVersion: "p", think: "off", now: now)
        let queued = try jobs(f)
        #expect(queued.count == 2 && queued.allSatisfy { $0.priority == 1 && $0.trialId == trial.id && $0.state == "waiting" })
        #expect(Set(queued.compactMap(\.imageId)) == [f.base.imageID, second])
        #expect(trial.counts == TrialCounts(waiting: 2, read: 0, skipped: 1, failed: 0) && trial.state == .running)
        let goneState = try store(f).state(trialID: trial.id, imageID: gone)
        #expect(goneState == .skipped)
    }

    @Test func capturesWithoutAnAnalysisAreLeftOutAndNothingToReadIsAnError() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        #expect(throws: TrialError.nothingToRead) { try store(f).create(model: "m", promptVersion: "p", think: "off", now: now) }
        let queued = try jobs(f), trials = try f.count("trials")
        #expect(queued.isEmpty && trials == 0)
    }

    @Test func savingAProposalKeepsItApartAndFinishesTheTrial() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.save([f.finding("Standup")])
        let before = try f.snapshot()
        let counts = (try f.count("findings"), try f.count("model_runs"), try f.count("image_analysis"))
        let trial = try store(f).create(model: "m2", promptVersion: "p", think: "off", now: now)
        let result = AnalysisResult(lines: [], classification: ClassificationResult(kind: .email, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: ""),
                                    findings: [f.finding("Standup (new)"), f.finding("Lunch", start: ReconcileFixture.minutes(180))], timezone: TimeZone(identifier: "UTC")!, model: "m2", pictureLongEdge: 2048)
        try store(f).saveProposal(trialID: trial.id, imageID: f.base.imageID, result: result, durationMs: 12, at: now)
        let done = try #require(try store(f).trial(id: trial.id))
        #expect(done.state == .finished && done.counts.read == 1 && done.finishedAt == now)
        let titles = try store(f).findings(trialID: trial.id, imageID: f.base.imageID).map(\.title).sorted()
        #expect(titles == ["Lunch", "Standup (new)"])
        // Nothing of the library moved (SC-001).
        let after = try f.snapshot()
        let now3 = (try f.count("findings"), try f.count("model_runs"), try f.count("image_analysis"))
        #expect(after == before)
        #expect(now3 == counts)
    }

    @Test func cancellingRemovesWaitingJobsAndResumingReadsWhatIsLeftIncludingFailures() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let second = try addKept(f, at: Date(timeIntervalSince1970: 1_800_100_000))
        for id in [f.base.imageID, second] { try f.save([f.finding("Standup")], imageID: id) }
        let s = store(f)
        let trial = try s.create(model: "m", promptVersion: "p", think: "off", now: now)
        try s.cancel(trial.id, now: now)
        let afterCancel = try jobs(f), cancelled = try s.trial(id: trial.id)
        #expect(afterCancel.isEmpty && cancelled?.state == .cancelled)
        try s.mark(trialID: trial.id, imageID: second, .failed, reason: "timeout", at: now)           // marking works only while waiting
        let partway = try s.trial(id: trial.id)
        #expect(partway?.counts == TrialCounts(waiting: 1, read: 0, skipped: 0, failed: 1))
        try s.resume(trial.id, now: now)
        let again = try jobs(f), resumed = try s.trial(id: trial.id)
        #expect(again.count == 2 && resumed?.state == .running && resumed?.counts.waiting == 2)
        try s.resume(trial.id, now: now)                                                             // no job is queued twice
        let twice = try jobs(f)
        #expect(twice.count == 2)
    }

    @Test func deletingATrialRemovesItsProposalsAndJobsButNotItems() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.save([f.finding("Standup")])
        let before = try f.snapshot()
        let s = store(f)
        let trial = try s.create(model: "m", promptVersion: "p", think: "off", now: now)
        try s.delete(trial.id)
        let trials = try s.all(), queued = try jobs(f), images = try f.count("trial_images"), proposals = try f.count("trial_findings")
        #expect(trials.isEmpty && queued.isEmpty && images == 0 && proposals == 0)
        let after = try f.snapshot()
        #expect(after == before)
    }

    @Test func deletingACaptureRemovesItsTrialRows() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.save([f.finding("Standup")])
        let s = store(f)
        let trial = try s.create(model: "m", promptVersion: "p", think: "off", now: now)
        let events = try f.read { try String.fetchAll($0, sql: "SELECT id FROM capture_events") }
        try f.base.captures.deleteEvents(ids: events)
        let images = try f.count("trial_images"), remaining = try s.trial(id: trial.id)
        #expect(images == 0 && remaining?.counts.total == 0)
    }

    @Test func outOfDateCountsCapturesReadWithAnotherModelOrPrompt() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let second = try f.addPicture(at: Date(timeIntervalSince1970: 1_800_100_000))
        try f.save([f.finding("A")]); try f.save([f.finding("B")], imageID: second)       // model "fake", classify calendar_week
        let current = ExtractionPrompts.currentVersions
        try f.write { try $0.execute(sql: "UPDATE image_analysis SET prompt_version = 'extract-calendar_week-v9'") }
        let stale = try store(f).outOfDateCount(model: "fake", currentPromptVersions: current)
        #expect(stale == 2)     // an older prompt version
        try f.write { try $0.execute(sql: "UPDATE image_analysis SET prompt_version = ?, classify_version = ?", arguments: [ExtractionPrompts.version(for: .calendarWeek, windowed: true), ExtractionPrompts.windowsVersion]) }
        let fresh = try store(f).outOfDateCount(model: "fake", currentPromptVersions: current)
        let otherModel = try store(f).outOfDateCount(model: "other", currentPromptVersions: current)
        #expect(fresh == 0 && otherModel == 2)
    }

    @Test func theMigrationAcceptsTheNewOperationKind() throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.write { try $0.execute(sql: """
            INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
            VALUES ('x', 'apply_trial', 1, '[]', '[]', '{}', '{}', NULL, datetime('now'))
            """) }
        let ops = try f.count("reconcile_ops")
        #expect(ops >= 1)
    }
}
