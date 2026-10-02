import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// A trial job reads one capture with the trial's model and keeps the result apart from the library (spec 008, US1).
@Suite struct TrialRunnerTests {
    private struct Rig {
        let fixture: ReconcileFixture
        let model: FakeModelChatting
        let recogniser: FakeTextRecogniser
        let runner: TrialJobRunner
        let store: TrialStore
    }

    private func makeRig(installed: String = "other:vl", lines: [RecognisedLine]? = nil) throws -> Rig {
        let fixture = try ReconcileFixture()
        let recogniser = FakeTextRecogniser(lines: lines ?? [RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
                                                             RecognisedLine(n: 2, text: "Room 4", box: PixelBox(x: 10, y: 50, width: 120, height: 18), confidence: 0.8)])
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer)
        model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Team sync","cited_lines":[1,2],"start_text":"10:00"}]}"#)
        let transport = FakeOllamaTransport()
        transport.set("/api/version", .json(#"{"version":"0.34.4"}"#))
        transport.set("/api/tags", .json(#"{"models":[{"name":"live:model","capabilities":["completion","vision"]},{"name":"\#(installed)","capabilities":["completion","vision"]}]}"#))
        let settings = OllamaSettings(store: FakeSettingsStore())
        settings.setModel("live:model")                                                  // the trial's model is another one
        let time = FakeTimeSource(1000)
        let service = OllamaService(settings: settings, makeTransport: { _ in transport }, time: time)
        let provider = StoredPictureProvider(paths: fixture.base.paths, store: fixture.base.captures)
        let store = TrialStore(database: fixture.database, paths: fixture.base.paths)
        let runner = TrialJobRunner(service: service, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: time), pictures: provider,
                                    fullPictures: provider, ocr: OCRStore(database: fixture.database), store: store, settings: settings, time: time,
                                    windows: fixture.base.captures, contexts: ContextStore(database: fixture.database))
        return Rig(fixture: fixture, model: model, recogniser: recogniser, runner: runner, store: store)
    }

    private func start(_ rig: Rig) throws -> (TrialRecord, AnalysisJobRecord) {
        try rig.fixture.save([rig.fixture.finding("Team sync")])
        try OCRStore(database: rig.fixture.database).save(imageID: rig.fixture.base.imageID, lines: [
            RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
            RecognisedLine(n: 2, text: "Room 4", box: PixelBox(x: 10, y: 50, width: 120, height: 18), confidence: 0.8)],
                                                          durationMs: 1, recogniser: "test", at: Date())
        let trial = try rig.store.create(model: "other:vl", promptVersion: "p", think: "off", now: Date())
        let job = try rig.fixture.read { try AnalysisJobRecord.fetchOne($0, sql: "SELECT * FROM analysis_jobs WHERE trial_id = ?", arguments: [trial.id])! }
        return (trial, job)
    }

    @Test func aTrialJobStoresTheProposalAndLeavesTheLibraryAsItWas() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let (trial, job) = try start(rig)
        let before = try rig.fixture.snapshot()
        let tables = ["findings", "model_runs", "image_analysis", "capture_tags", "window_readings", "evidence"]
        var counts: [Int] = []
        for table in tables { counts.append(try rig.fixture.count(table)) }
        let outcome = await rig.runner.run(job, attempt: 1)
        #expect(outcome == .success)
        let proposals = try rig.store.findings(trialID: trial.id, imageID: rig.fixture.base.imageID)
        #expect(proposals.map(\.title) == ["Team sync"])
        var after: [Int] = []
        for table in tables { after.append(try rig.fixture.count(table)) }
        #expect(after == counts)
        let snapshot = try rig.fixture.snapshot()
        #expect(snapshot == before)
        let record = try #require(try rig.store.trial(id: trial.id))
        #expect(record.state == .finished && record.counts.read == 1)
        #expect(rig.recogniser.callCount == 0)                                           // the stored text was reused
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").first?.model == "other:vl")
    }

    @Test func aTrialOfAWindowCaptureReadsItAsTheChosenWindowAndOtherCapturesAsBefore() async throws {
        let window = #"{"windows":[{"key":"w0","relevant":false,"kind":"other","confidence":0.8,"remote":false,"calendar_name":""}],"application":"Mail","platform_look":"macos","theme":"light","remote_session":{"is_remote":false,"client":""}}"#
        // A full-screen capture with one recorded window is read whole: no windows call.
        let plain = try makeRig(); defer { plain.fixture.cleanUp() }
        let (_, plainJob) = try start(plain)
        let plainImage = plain.fixture.base.imageID
        try await plain.fixture.base.captures.database.pool.write { db in
            try db.execute(sql: "INSERT INTO capture_windows (id, image_id, z, app_name, bundle_id, title, x, y, width, height, stack) VALUES ('w', ?, 0, 'Mail', 'com.example.mail', 'Inbox', 0, 0, 1200, 600, 0)",
                           arguments: [plainImage])
        }
        _ = await plain.runner.run(plainJob, attempt: 1)
        #expect(plain.model.requests(whereSchemaHas: "windows").isEmpty && plain.model.requests(whereSchemaHas: "screen_kind").count == 1)

        // The same capture marked as a window capture takes the chosen-window path.
        let chosen = try makeRig(); defer { chosen.fixture.cleanUp() }
        let (trial, chosenJob) = try start(chosen)
        let chosenImage = chosen.fixture.base.imageID
        try await chosen.fixture.base.captures.database.pool.write { db in
            try db.execute(sql: "INSERT INTO capture_windows (id, image_id, z, app_name, bundle_id, title, x, y, width, height, stack) VALUES ('w', ?, 0, 'Mail', 'com.example.mail', 'Inbox', 0, 0, 1200, 600, 0)",
                           arguments: [chosenImage])
            try db.execute(sql: "UPDATE capture_events SET scope = 'window'")
        }
        chosen.model.answer(whenSchemaHas: "windows", window)
        _ = await chosen.runner.run(chosenJob, attempt: 1)
        #expect(chosen.model.requests(whereSchemaHas: "windows").count == 1 && chosen.model.requests(whereSchemaHas: "screen_kind").isEmpty)
        #expect(try chosen.store.findings(trialID: trial.id, imageID: chosen.fixture.base.imageID).map(\.title) == ["Team sync"])
    }

    @Test func aCancelledTrialOrACaptureAlreadyReadIsNotReadAgain() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let (trial, job) = try start(rig)
        try rig.store.cancel(trial.id, now: Date())
        let cancelled = await rig.runner.run(job, attempt: 1)
        #expect(cancelled == .success && rig.model.requests(whereSchemaHas: "screen_kind").isEmpty)
        try rig.store.resume(trial.id, now: Date())
        _ = await rig.runner.run(job, attempt: 1)
        let calls = rig.model.requests(whereSchemaHas: "screen_kind").count
        _ = await rig.runner.run(job, attempt: 1)                                       // a restart repeats the job: nothing is read twice (SC-007)
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").count == calls && calls == 1)
    }

    @Test func aPictureThatIsGoneIsSkippedNotFailed() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let (trial, job) = try start(rig)
        try rig.fixture.base.captures.markMissing(imageID: rig.fixture.base.imageID)
        let outcome = await rig.runner.run(job, attempt: 1)
        let state = try rig.store.state(trialID: trial.id, imageID: rig.fixture.base.imageID)
        #expect(outcome == .success && state == .skipped)
    }

    @Test func aTrialModelThatIsNotInstalledFailsThatCaptureInsteadOfStallingTheQueue() async throws {
        let rig = try makeRig(installed: "something:else"); defer { rig.fixture.cleanUp() }
        let (trial, job) = try start(rig)
        let outcome = await rig.runner.run(job, attempt: 1)
        let state = try rig.store.state(trialID: trial.id, imageID: rig.fixture.base.imageID)
        guard case .permanent(let reason) = outcome else { Issue.record("expected permanent, got \(outcome)"); return }
        #expect(state == .failed && reason.contains("other:vl"))
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").isEmpty)
    }

    @Test func theUsersChoiceOfContextDecidesTheZoneDatesAreReadInAsInLiveAnalysis() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let (trial, job) = try start(rig)
        let contexts = ContextStore(database: rig.fixture.database)
        let tokyo = try contexts.add(name: "Tokyo office", timezone: "Asia/Tokyo", hints: [])
        try contexts.setUserChoice(imageID: rig.fixture.base.imageID, contextID: tokyo.id, at: Date())
        _ = await rig.runner.run(job, attempt: 1)
        let proposals = try rig.store.findings(trialID: trial.id, imageID: rig.fixture.base.imageID)
        #expect(proposals.first?.timezone == "Asia/Tokyo")
    }

    @Test func trialJobsAreNotCountedWithTheCapturesOfTheMenu() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = try start(rig)
        let counts = try AnalysisStore(database: rig.fixture.database).counts()
        #expect(counts.waiting == 0)
        let hasPending = try AnalysisStore(database: rig.fixture.database).hasPendingAnalysis(imageID: rig.fixture.base.imageID)
        #expect(!hasPending)
    }

    @Test func trialJobsRunAfterNewCaptures() throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let (_, trialJob) = try start(rig)
        let jobs = AnalysisStore(database: rig.fixture.database)
        let live = AnalysisJobRecord(kind: "analyse", imageId: rig.fixture.base.imageID, createdAt: Date().addingTimeInterval(60))
        try jobs.enqueue(live)
        let next = try jobs.nextRunnable(now: Date().addingTimeInterval(120))
        #expect(next?.id == live.id && trialJob.priority == 1)
    }
}
