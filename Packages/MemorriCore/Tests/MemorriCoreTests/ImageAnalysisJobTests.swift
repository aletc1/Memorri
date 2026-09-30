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
    }

    private func sampleLines() -> [RecognisedLine] {
        [RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
         RecognisedLine(n: 2, text: "Room 4", box: PixelBox(x: 10, y: 50, width: 120, height: 18), confidence: 0.8)]
    }

    private func makeRig(lines: [RecognisedLine]? = nil, failWith error: Error? = nil, model modelName: String? = "qwen3.8:27b-mlx") throws -> Rig {
        let fixture = try makePipelineFixture()
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
        let runner = ImageAnalysisJobRunner(service: service, pipeline: pipeline, pictures: provider, fullPictures: provider, ocr: ocr,
                                            results: results, jobs: jobs, settings: settings, time: time)
        return Rig(fixture: fixture, recogniser: recogniser, model: model, runner: runner, ocr: ocr, results: results, jobs: jobs, settings: settings)
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
        #expect(run.imageId == rig.fixture.imageID && run.promptVersion == "classify-v1" && run.temperature == 0)
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
        #expect(extract.promptVersion == "extract-calendar_week-v1" && extract.imageLongEdge == 600)
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
}
