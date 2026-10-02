import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ImageAnalysisJobTests {
    private struct Rig {
        let fixture: PipelineFixture
        let recogniser: FakeTextRecogniser
        let model: FakeModelChatting
        let runner: ImageAnalysisJobRunner
        let ocr: OCRStore
        let results: AnalysisResultStore
        let jobs: AnalysisStore
        let settings: OllamaSettings
        let contexts: ContextStore
        let reconciler: FakeReconciler
        let evidence: FakeEvidenceWriter
    }

    private func sampleLines() -> [RecognisedLine] {
        [RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
         RecognisedLine(n: 2, text: "Room 4", box: PixelBox(x: 10, y: 50, width: 120, height: 18), confidence: 0.8)]
    }

    private func makeRig(lines: [RecognisedLine]? = nil, failWith error: Error? = nil, model modelName: String? = "qwen3.8:27b-mlx",
                         windows: [WindowInfo] = [], reconcileSummary: ReconcileSummary = ReconcileSummary()) throws -> Rig {
        let fixture = try makePipelineFixture(windows: windows)
        let recogniser = FakeTextRecogniser(lines: lines ?? sampleLines(), failWith: error)
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer)
        model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Team sync","cited_lines":[1,2],"start_text":"10:00"}]}"#)
        let transport = FakeOllamaTransport()
        transport.set("/api/version", .json(#"{"version":"0.34.4"}"#))
        transport.set("/api/tags", .json(#"{"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision","thinking"]}]}"#))
        let settings = OllamaSettings(store: FakeSettingsStore())
        settings.setModel(modelName)
        let time = FakeTimeSource(1000)
        let service = OllamaService(settings: settings, makeTransport: { _ in transport }, time: time)
        let ocr = OCRStore(database: fixture.database)
        let results = AnalysisResultStore(database: fixture.database)
        let provider = StoredPictureProvider(paths: fixture.paths, store: fixture.captures)
        let jobs = AnalysisStore(database: fixture.database)
        let pipeline = AnalysisPipeline(recogniser: recogniser, model: model, time: time)
        let reconciler = FakeReconciler(summary: reconcileSummary)
        reconciler.database = fixture.database
        let evidence = FakeEvidenceWriter()
        evidence.reconciler = reconciler
        let runner = ImageAnalysisJobRunner(service: service, pipeline: pipeline, pictures: provider, fullPictures: provider, ocr: ocr,
                                            results: results, jobs: jobs, settings: settings, time: time,
                                            contexts: ContextStore(database: fixture.database), windows: fixture.captures,
                                            reconciler: reconciler, evidence: evidence)
        return Rig(fixture: fixture, recogniser: recogniser, model: model, runner: runner, ocr: ocr, results: results, jobs: jobs, settings: settings,
                   contexts: ContextStore(database: fixture.database), reconciler: reconciler, evidence: evidence)
    }

    private func job(_ rig: Rig, kind: String = "analyse", imageID: String? = nil, nilImage: Bool = false) throws -> AnalysisJobRecord {
        let job = AnalysisJobRecord(kind: kind, imageId: nilImage ? nil : (imageID ?? rig.fixture.imageID), createdAt: Date())
        try rig.jobs.enqueue(job)
        return job
    }

    private func runs(_ rig: Rig) throws -> [ModelRunRecord] {
        try rig.fixture.database.pool.read { try ModelRunRecord.fetchAll($0, sql: "SELECT * FROM model_runs ORDER BY started_at, attempt") }
    }

    // MARK: Read

    @Test func anAnalyseJobReadsTheFullResolutionCopyAndStoresItsLines() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.imageSizes.map { [$0.0, $0.1] } == [[1200, 600]])
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID) == sampleLines())
    }

    @Test func aSecondRunDoesNotReadAgain() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.callCount == 1)
    }

    @Test func aForcedRunReadsAndAsksAgain() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let outcome = await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.recogniser.callCount == 2 && rig.model.requests(whereSchemaHas: "screen_kind").count == 2)
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID).count == 2)
    }

    @Test func aPictureWithNoTextSucceedsWithZeroLines() async throws {
        let rig = try makeRig(lines: []); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(try rig.ocr.isRead(imageID: rig.fixture.imageID))
        #expect(try rig.ocr.lines(imageID: rig.fixture.imageID).isEmpty)
    }

    @Test func aMissingPictureIsPermanentAndWritesNothing() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let unknown = await rig.runner.run(try job(rig, imageID: "unknown"), attempt: 1)
        let noPicture = await rig.runner.run(try job(rig, nilImage: true), attempt: 1)
        try rig.fixture.captures.markMissing(imageID: rig.fixture.imageID)
        let marked = await rig.runner.run(try job(rig), attempt: 1)
        #expect([unknown, noPicture, marked] == Array(repeating: JobOutcome.permanent("picture no longer stored"), count: 3))
        #expect(rig.recogniser.callCount == 0 && rig.model.callCount == 0)
        let reads = try await rig.fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ocr_reads") }
        #expect(reads == 0)
    }

    @Test func aRecogniserErrorIsTransientAndWritesNothing() async throws {
        let rig = try makeRig(failWith: CocoaError(.fileReadUnknown)); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .transient("text recognition failed"))
        #expect(try rig.ocr.isRead(imageID: rig.fixture.imageID) == false)
        #expect(rig.model.callCount == 0)
    }

    // MARK: Classify

    @Test func theClassificationCallIsRecordedWithItsStepAndRawAnswer() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let queued = try job(rig)
        let outcome = await rig.runner.run(queued, attempt: 2)
        #expect(outcome == .success)
        let recorded = try runs(rig)
        #expect(recorded.map(\.step) == ["classify", "extract"])
        let run = try #require(recorded.first)
        #expect(run.step == "classify" && run.outcome == "success" && run.attempt == 2 && run.jobId == queued.id)
        #expect(run.imageId == rig.fixture.imageID && run.promptVersion == "classify-v2" && run.temperature == 0)
        #expect(run.rawAnswer?.contains("calendar_week") == true)
        #expect(!run.requestJson.contains("base64"))
        // The stored analysis copy is 600 x 300, smaller than 1024: it is not enlarged.
        #expect(run.imageLongEdge == 600)
        #expect(rig.model.requests.count == 2 && rig.model.requests[0].picture != nil)
    }

    @Test func aFailedCallIsRecordedAsFailedAndMapsToTheOutcome() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        rig.model.answer(whenSchemaHas: "screen_kind", #"{"screen_kind":"spreadsheet"}"#)
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .transient("invalid answer"))
        let run = try #require(try runs(rig).first)
        #expect(run.outcome == "failed" && run.failureReason == "invalid answer" && run.rawAnswer != nil)
        // The lines were already kept: the retry does not read again.
        #expect(try rig.ocr.isRead(imageID: rig.fixture.imageID))
    }

    @Test func aRetryReusesTheStoredClassification() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").count == 1)
        #expect(rig.model.requests(whereSchemaHas: "findings").count == 2)
        #expect(try runs(rig).map(\.step) == ["classify", "extract", "extract"])
    }

    @Test func anUnreachableServerMidCallIsServerUnavailableAndNothingIsRecorded() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        rig.model.failWith(OllamaClientError.unreachable)
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .serverUnavailable)
        #expect(try runs(rig).isEmpty)
    }

    @Test func noChosenModelIsServerUnavailable() async throws {
        let rig = try makeRig(model: nil); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .serverUnavailable)
        #expect(rig.recogniser.callCount == 0 && rig.model.callCount == 0)
    }

    // MARK: Extract and store

    @Test func theFindingsAreStoredWithTheExtractionRun() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        let extract = try #require(try runs(rig).first { $0.step == "extract" })
        #expect(extract.promptVersion == ExtractionPrompts.version(for: .calendarWeek) && extract.imageLongEdge == 600)
        let stored = try #require(try rig.results.analysis(imageID: rig.fixture.imageID))
        #expect(stored.kind == .calendarWeek && stored.findingCount == 1 && stored.extractRunID == extract.id && stored.model == "qwen3.8:27b-mlx")
        let findings = try rig.results.findings(imageID: rig.fixture.imageID)
        #expect(findings.map(\.title) == ["Team sync"] && findings[0].citedLines == [1, 2] && findings[0].unresolved.isEmpty)
        // "10:00" with no header or date: the day of the capture, in the zone it was stored with.
        let zone = TimeZone(identifier: findings[0].timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let captured = try #require(try rig.fixture.captures.capturedAt(eventID: rig.fixture.event.id))
        let day = calendar.dateComponents([.year, .month, .day], from: captured)
        let expected = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 10, minute: 0))
        #expect(findings[0].start == expected && findings[0].provenance["start"]?.rule == "time-only")
    }

    @Test func aSecondRunOfThePictureLeavesOneSetOfFindings() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        _ = await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1)
        #expect(try rig.results.findings(imageID: rig.fixture.imageID).count == 1)
        let count = try await rig.fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM findings") }
        #expect(count == 1)
    }

    @Test func aFailedExtractionKeepsTheClassificationAndStoresNoAnalysis() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"x"}]}"#)
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .transient("invalid answer"))
        #expect(try runs(rig).map(\.step) == ["classify", "extract"])
        #expect(try runs(rig).map(\.outcome) == ["success", "failed"])
        #expect(try rig.results.analysis(imageID: rig.fixture.imageID) == nil)
        // The retry asks only for the findings.
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        let retry = await rig.runner.run(try job(rig), attempt: 2)
        #expect(retry == .success)
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").count == 1 && rig.model.requests(whereSchemaHas: "findings").count == 2)
    }

    @Test func aBadCitationIsDiscardedAndRecorded() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"Good","cited_lines":[1]},{"kind":"task","title":"Invented","cited_lines":[99]}]}"#)
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let stored = try #require(try rig.results.analysis(imageID: rig.fixture.imageID))
        #expect(stored.findingCount == 1 && stored.discarded.map(\.title) == ["Invented"])
    }

    // MARK: Context

    private func titled(_ title: String) -> WindowInfo {
        WindowInfo(appName: "Outlook", bundleID: nil, title: title, frame: PixelBox(x: 0, y: 0, width: 1000, height: 500))
    }

    @Test func theStoredWindowsPickTheContextAndItsZoneIsUsed() async throws {
        let rig = try makeRig(windows: [titled("Inbox - Customer A - Outlook")]); defer { rig.fixture.cleanUp() }
        let a = try rig.contexts.add(name: "Customer A", timezone: "America/New_York", hints: [ContextHint(kind: .windowTitle, value: "Customer A")])
        try rig.contexts.add(name: "Customer B", timezone: "Asia/Tokyo", hints: [ContextHint(kind: .windowTitle, value: "Customer B")])
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .success)
        let decision = try #require(try rig.contexts.decision(imageID: rig.fixture.imageID))
        #expect(decision.contextID == a.id && decision.source == .auto && decision.score == 3)
        let stored = try #require(try rig.results.analysis(imageID: rig.fixture.imageID))
        #expect(stored.timezone == "America/New_York" && stored.timezoneSource == "context")
        #expect(try rig.results.findings(imageID: rig.fixture.imageID).first?.timezone == "America/New_York")
    }

    @Test func noMatchLeavesThePictureUnassignedOnTheMacsZone() async throws {
        let rig = try makeRig(windows: [titled("Something else")]); defer { rig.fixture.cleanUp() }
        try rig.contexts.add(name: "Customer A", timezone: "America/New_York", hints: [ContextHint(kind: .windowTitle, value: "Customer A")])
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .success)
        let decision = try #require(try rig.contexts.decision(imageID: rig.fixture.imageID))
        #expect(decision.contextID == nil && decision.source == .none)
        #expect(try rig.results.analysis(imageID: rig.fixture.imageID)?.timezoneSource == "mac")
    }

    @Test func aUserChoiceSurvivesAForcedAnalysisAndKeepsItsZone() async throws {
        let rig = try makeRig(windows: [titled("Customer A")]); defer { rig.fixture.cleanUp() }
        try rig.contexts.add(name: "Customer A", timezone: "America/New_York", hints: [ContextHint(kind: .windowTitle, value: "Customer A")])
        let b = try rig.contexts.add(name: "Customer B", timezone: "Asia/Tokyo", hints: [])
        _ = await rig.runner.run(try job(rig), attempt: 1)
        try rig.contexts.setUserChoice(imageID: rig.fixture.imageID, contextID: b.id, at: Date())
        #expect(await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1) == .success)
        let decision = try #require(try rig.contexts.decision(imageID: rig.fixture.imageID))
        #expect(decision.contextID == b.id && decision.source == .user)
        #expect(try rig.results.analysis(imageID: rig.fixture.imageID)?.timezone == "Asia/Tokyo")
    }

    @Test func deletingAContextLeavesItsFindings() async throws {
        let rig = try makeRig(windows: [titled("Customer A")]); defer { rig.fixture.cleanUp() }
        let a = try rig.contexts.add(name: "Customer A", timezone: nil, hints: [ContextHint(kind: .windowTitle, value: "Customer A")])
        _ = await rig.runner.run(try job(rig), attempt: 1)
        try rig.contexts.delete(id: a.id)
        #expect(try rig.contexts.decision(imageID: rig.fixture.imageID)?.contextID == nil)
        #expect(try rig.results.findings(imageID: rig.fixture.imageID).count == 1)
    }

    // MARK: Reconcile (spec 005)

    @Test func theAnalysisIsReconciledOnceAfterItIsStored() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.reconciler.imageIDs == [rig.fixture.imageID])
        // it is asked after the analysis is in the database
        #expect(rig.reconciler.analysisWasStoredWhenAsked == [true])
    }

    @Test func evidenceIsWrittenOnceAfterReconciliationAndNeverFailsTheJob() async throws {
        let rig = try makeRig(reconcileSummary: ReconcileSummary(error: "database error")); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(rig.evidence.imageIDs == [rig.fixture.imageID] && rig.evidence.reconciledFirst == [true])
        _ = await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1)
        #expect(rig.evidence.imageIDs.count == 2)
    }

    @Test func aJobThatFailsBeforeStoringWritesNoEvidence() async throws {
        let rig = try makeRig(failWith: CocoaError(.fileReadUnknown)); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        #expect(rig.evidence.imageIDs.isEmpty)
    }

    @Test func aReconcileErrorLeavesTheJobSucceededAndTheAnalysisStored() async throws {
        let rig = try makeRig(reconcileSummary: ReconcileSummary(error: "database error")); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome == .success)
        #expect(try rig.results.analysis(imageID: rig.fixture.imageID) != nil)
    }

    @Test func aJobThatFailsBeforeStoringDoesNotReconcile() async throws {
        let rig = try makeRig(failWith: CocoaError(.fileReadUnknown)); defer { rig.fixture.cleanUp() }
        let outcome = await rig.runner.run(try job(rig), attempt: 1)
        #expect(outcome != .success)
        #expect(rig.reconciler.imageIDs.isEmpty)
    }

    @Test func eachNewAnalysisOfThePictureIsReconciledAgain() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        _ = await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1)
        #expect(rig.reconciler.imageIDs.count == 2)
    }

    // MARK: Windows (spec 011)

    private func windowedLines() -> [RecognisedLine] {
        let mail = ["From: Ana Ruiz", "Subject: Planning", "Planning meeting tomorrow at 10:00", "Date: Wed 14 Oct 2026 09:00"]
        let terminal = ["$ ls -la", "drwxr-xr-x  5 user  staff", "-rw-r--r--  1 user  staff", "$ make build"]
        return mail.enumerated().map { RecognisedLine(n: $0.offset + 1, text: $0.element, box: PixelBox(x: 620, y: 40 + $0.offset * 30, width: 300, height: 18), confidence: 0.9) }
            + terminal.enumerated().map { RecognisedLine(n: $0.offset + 5, text: $0.element, box: PixelBox(x: 20, y: 300 + $0.offset * 30, width: 300, height: 18), confidence: 0.9) }
    }

    private let twoWindows = [WindowInfo(appName: "Mail", bundleID: "com.example.mail", title: "Inbox", frame: PixelBox(x: 600, y: 20, width: 560, height: 500), stack: 0),
                              WindowInfo(appName: "Terminal", bundleID: "com.example.terminal", title: "zsh", frame: PixelBox(x: 0, y: 20, width: 1200, height: 560), stack: 1)]

    private func windowsAnswer(mailRelevant: Bool = true) -> String {
        #"""
        {"windows":[{"key":"w0","relevant":\#(mailRelevant),"kind":"email","confidence":0.9,"remote":false,"calendar_name":""},
                    {"key":"w1","relevant":false,"kind":"other","confidence":0.9,"remote":false,"calendar_name":""}],
         "application":"Mail","platform_look":"macos","theme":"light","remote_session":{"is_remote":false,"client":""}}
        """#
    }

    private func windowedRig() throws -> Rig {
        let rig = try makeRig(lines: windowedLines(), windows: twoWindows)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer())
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[3],"start_text":"10:00","date_text":"tomorrow"}]}"#)
        return rig
    }

    private func readings(_ rig: Rig) throws -> [WindowReadingRecord] { try WindowReadingStore(database: rig.fixture.database).readings(imageID: rig.fixture.imageID) }

    @Test func aCaptureWithWindowsStoresTheirReadingsAndTheWindowKeysOfItsFindings() async throws {
        let rig = try windowedRig(); defer { rig.fixture.cleanUp() }
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .success)
        let stored = try readings(rig)
        #expect(stored.map(\.windowKey) == ["w0", "w1"] && stored.map(\.relevant) == [true, false] && stored.map(\.appName) == ["Mail", "Terminal"])
        let findings = try rig.results.findings(imageID: rig.fixture.imageID)
        #expect(findings.map(\.title) == ["Planning meeting"] && findings.map(\.windowKey) == ["w0"])
        let analysis = try #require(try rig.results.analysis(imageID: rig.fixture.imageID))
        #expect(analysis.classifyVersion == "windows-v1" && analysis.windowsRead == 1 && analysis.kind == .email)
        let run = try #require(try runs(rig).first { $0.step == "windows" })
        #expect(run.promptVersion == "windows-v1")
        #expect(stored.allSatisfy { $0.runID == run.id })
        #expect(try runs(rig).map(\.step) == ["windows", "extract:w0"])
    }

    @Test func theWindowsCallIsSentAtTheClassificationSizeAndTheExtractionAtTheWindowsOwn() async throws {
        let rig = try windowedRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let stored = try runs(rig)
        let windows = try #require(stored.first { $0.step == "windows" }), extract = try #require(stored.first { $0.step == "extract:w0" })
        #expect(windows.imageLongEdge == 600)                  // the analysis copy of this fixture is smaller than 1024, so it is not enlarged
        #expect(extract.promptVersion == "extract-email-v13")
    }

    @Test func readingsAreReplacedWhenThePictureIsAnalysedAgain() async throws {
        let rig = try windowedRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer(mailRelevant: false))
        _ = await rig.runner.run(try job(rig, kind: "analyse-force"), attempt: 1)
        let stored = try readings(rig)
        #expect(stored.count == 2 && stored.map(\.relevant) == [false, false])
        #expect(try rig.results.findings(imageID: rig.fixture.imageID).isEmpty)
    }

    @Test func readingsGoWithTheirCapture() async throws {
        let rig = try windowedRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        #expect(try readings(rig).count == 2)
        try await rig.fixture.database.pool.write { try $0.execute(sql: "DELETE FROM capture_images WHERE id = ?", arguments: [rig.fixture.imageID]) }
        #expect(try readings(rig).isEmpty)
    }

    @Test func aCaptureWithoutWindowsKeepsTheClassifyStepAndStoresNoReadings() async throws {
        let rig = try makeRig(); defer { rig.fixture.cleanUp() }
        _ = await rig.runner.run(try job(rig), attempt: 1)
        #expect(try readings(rig).isEmpty)
        #expect(try runs(rig).map(\.step) == ["classify", "extract"])
        #expect(try rig.results.analysis(imageID: rig.fixture.imageID)?.classifyVersion == "classify-v2")
    }
}

/// Records the pictures it is asked to write evidence for, and whether the picture was reconciled by then.
final class FakeEvidenceWriter: ImageEvidenceWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var reconciledWhenAsked: [Bool] = []
    var reconciler: FakeReconciler?

    var imageIDs: [String] { lock.withLock { asked } }
    var reconciledFirst: [Bool] { lock.withLock { reconciledWhenAsked } }

    func write(imageID: String) async -> Int {
        lock.withLock {
            asked.append(imageID)
            reconciledWhenAsked.append(reconciler?.imageIDs.contains(imageID) ?? false)
        }
        return 0
    }
}

/// Records the pictures it is asked to reconcile, and whether their analysis was already stored by then.
final class FakeReconciler: ImageReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private let summary: ReconcileSummary
    private var asked: [String] = []
    private var stored: [Bool] = []
    var database: StorageDatabase?

    init(summary: ReconcileSummary = ReconcileSummary()) { self.summary = summary }

    var imageIDs: [String] { lock.withLock { asked } }
    var analysisWasStoredWhenAsked: [Bool] { lock.withLock { stored } }

    func reconcile(imageID: String) async -> ReconcileSummary {
        let analysed = database.flatMap { (try? AnalysisResultStore(database: $0).analysis(imageID: imageID)) ?? nil } != nil
        lock.withLock { asked.append(imageID); stored.append(analysed) }
        return summary
    }
}
