import CoreGraphics
import Foundation
import Testing
@testable import MemorriCore

@Suite struct AnalysisPipelineTests {
    private let settings = ModelStepSettings(model: "m", think: .off, timeout: 60, modelThinks: false)

    private func lines() -> [RecognisedLine] {
        [RecognisedLine(n: 1, text: "Mon 12", box: PixelBox(x: 10, y: 10, width: 80, height: 18), confidence: 0.9)]
    }

    private struct Rig {
        let recogniser: FakeTextRecogniser
        let model: FakeModelChatting
        let pipeline: AnalysisPipeline
    }

    private func makeRig(confidence: String = "0.93", answer: String? = nil) -> Rig {
        let recogniser = FakeTextRecogniser(lines: [RecognisedLine(n: 1, text: "Mon 12", box: PixelBox(x: 10, y: 10, width: 80, height: 18), confidence: 0.9)])
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", answer ?? ClassificationTests.goodAnswer.replacingOccurrences(of: "0.93", with: confidence))
        model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        return Rig(recogniser: recogniser, model: model, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: FakeTimeSource(1000)))
    }

    private func input(reuse: PipelineInput.Reuse = .init()) -> PipelineInput {
        PipelineInput(image: makeTestImage(width: 1200, height: 600), classificationJPEG: Data("jpeg-bytes".utf8),
                      classificationSize: (1024, 512), analysisJPEG: Data("analysis-bytes".utf8), analysisSize: (2048, 1024), reuse: reuse)
    }

    @Test func aRunReadsThePictureAndAsksOnceForTheKind() async throws {
        let rig = makeRig()
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        #expect(rig.recogniser.callCount == 1)
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").count == 1)
        #expect(rig.model.requests[0].picture == Data("jpeg-bytes".utf8))
        #expect(result.lines == lines())
        #expect(result.classification.kind == .calendarWeek)
        #expect(result.classification.application == "Outlook" && result.classification.platformLook == "windows")
        #expect(result.classification.isRemote && result.classification.remoteClient == "Citrix" && result.classification.theme == "light")
    }

    @Test func anUnsureAnswerBecomesOther() async throws {
        let rig = makeRig(confidence: "0.3")
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        #expect(result.classification.kind == .other && result.classification.modelKind == .calendarWeek)
    }

    @Test func theStepRecordKeepsTheRawAnswerAndNoPictureData() async throws {
        let rig = makeRig()
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        let step = try #require(result.steps.first)
        #expect(result.steps.map(\.step) == ["classify", "extract"] && step.step == "classify")
        #expect(step.failure == nil && step.rawAnswer?.contains("calendar_week") == true)
        #expect(step.promptVersion == "classify-v1")
        #expect(step.request.contains("[picture 1024x512]"))
        #expect(!step.request.contains(Data("jpeg-bytes".utf8).base64EncodedString()))
    }

    @Test func anAnswerThatBreaksTheSchemaIsTransientAndKeepsTheFailedStep() async throws {
        let rig = makeRig(answer: #"{"screen_kind":"spreadsheet"}"#)
        do {
            _ = try await rig.pipeline.analyse(input(), settings: settings)
            Issue.record("should fail")
        } catch let failure as AnalysisFailure {
            #expect(failure.error == .transient("invalid answer"))
            #expect(failure.steps.count == 1 && failure.steps[0].failure == "invalid answer" && failure.steps[0].rawAnswer != nil)
        }
    }

    @Test func anUnreachableServerIsServerUnavailable() async throws {
        let rig = makeRig()
        rig.model.failWith(OllamaClientError.unreachable)
        do {
            _ = try await rig.pipeline.analyse(input(), settings: settings)
            Issue.record("should fail")
        } catch let failure as AnalysisFailure {
            #expect(failure.error == .serverUnavailable)
        }
    }

    @Test func aRecogniserErrorIsTransient() async throws {
        let recogniser = FakeTextRecogniser(failWith: CocoaError(.fileReadUnknown))
        let pipeline = AnalysisPipeline(recogniser: recogniser, model: FakeModelChatting(), time: FakeTimeSource(1000))
        do {
            _ = try await pipeline.analyse(input(), settings: settings)
            Issue.record("should fail")
        } catch let failure as AnalysisFailure {
            #expect(failure.error == .transient("text recognition failed") && failure.steps.isEmpty)
        }
    }

    @Test func aResumedRunWithStoredLinesAndKindOnlyExtracts() async throws {
        let rig = makeRig()
        let stored = try #require(ClassificationResult.parse(storedAnswer: ClassificationTests.goodAnswer))
        let result = try await rig.pipeline.analyse(input(reuse: .init(lines: lines(), classification: stored)), settings: settings)
        #expect(rig.recogniser.callCount == 0 && rig.model.requests(whereSchemaHas: "screen_kind").isEmpty)
        #expect(rig.model.requests(whereSchemaHas: "findings").count == 1)
        #expect(result.lines == lines() && result.classification.kind == .calendarWeek && result.steps.map(\.step) == ["extract"])
    }

    @Test func aResumedRunWithOnlyStoredLinesStillAsksForTheKind() async throws {
        let rig = makeRig()
        _ = try await rig.pipeline.analyse(input(reuse: .init(lines: lines(), classification: nil)), settings: settings)
        #expect(rig.recogniser.callCount == 0 && rig.model.requests(whereSchemaHas: "screen_kind").count == 1)
    }

    // MARK: Extraction

    private func extractAnswer(_ findings: String) -> String { #"{"findings":[\#(findings)]}"# }

    @Test func afterClassificationTheModelIsAskedForTheFindingsOfThatKind() async throws {
        let rig = makeRig()
        rig.model.answer(whenSchemaHas: "findings", extractAnswer(#"{"kind":"appointment","title":"Team sync","cited_lines":[1],"start_text":"10:00"}"#))
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        let calls = rig.model.requests(whereSchemaHas: "findings")
        #expect(rig.model.callCount == 2 && calls.count == 1)
        let request = try #require(calls.first)
        #expect(request.prompt.contains("week calendar") && request.prompt.contains("L1 (0%,1%) Mon 12"))
        #expect(request.schema == ExtractionSchemas.extractSchema(for: .calendarWeek))
        #expect(request.picture == Data("analysis-bytes".utf8))
        let step = try #require(result.steps.last)
        #expect(step.step == "extract" && step.promptVersion == "extract-calendar_week-v1" && step.schemaVersion == "schema-calendar_week-v1")
        #expect(result.findings.count == 1 && result.findings[0].title == "Team sync" && result.findings[0].citedLines == [1])
        #expect(result.findings[0].kind == .appointment && result.findings[0].confidence == 0.9)
        #expect(result.model == "m" && result.pictureLongEdge == 2048 && !result.lineCapApplied)
    }

    @Test func aFindingWithABadCitationIsDiscardedAndTheOthersStay() async throws {
        let rig = makeRig()
        rig.model.answer(whenSchemaHas: "findings", extractAnswer(#"""
        {"kind":"task","title":"Good","cited_lines":[1]},{"kind":"task","title":"Invented","cited_lines":[42]},{"kind":"task","title":"Uncited","cited_lines":[]}
        """#))
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        #expect(result.findings.map(\.title) == ["Good"])
        #expect(result.discards.map(\.title) == ["Invented", "Uncited"])
    }

    @Test func anEmptyListIsAnAnalysedResultWithNoFindings() async throws {
        let rig = makeRig()
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        #expect(result.findings.isEmpty && result.discards.isEmpty && result.steps.count == 2)
    }

    @Test func anExtractionAnswerThatBreaksTheSchemaIsTransientAndKeepsBothSteps() async throws {
        let rig = makeRig()
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"x"}]}"#)
        do {
            _ = try await rig.pipeline.analyse(input(), settings: settings)
            Issue.record("should fail")
        } catch let failure as AnalysisFailure {
            #expect(failure.error == .transient("invalid answer"))
            #expect(failure.steps.map(\.step) == ["classify", "extract"] && failure.steps[1].failure == "invalid answer")
        }
    }

    @Test func aNeedsSentenceArrivesAsATaskForThatPerson() async throws {
        let rig = makeRig()
        rig.model.answer(whenSchemaHas: "findings", extractAnswer(#"""
        {"kind":"task","title":"Send the report","cited_lines":[1],"due_text":"Friday","people":["Anna"]}
        """#))
        let finding = try #require(try await rig.pipeline.analyse(input(), settings: settings).findings.first)
        #expect(finding.kind == .task && finding.people == ["Anna"] && finding.title == "Send the report")
    }

    @Test func datesStayAsWrittenAndAreListedAsUnresolved() async throws {
        let rig = makeRig()
        rig.model.answer(whenSchemaHas: "findings", extractAnswer(#"""
        {"kind":"appointment","title":"Sync","cited_lines":[1],"date_text":"Wed 14","start_text":"10:00","end_text":"11:00","remind_text":"15 min before"},
        {"kind":"deadline","title":"Submit","cited_lines":[1],"due_text":"Friday","all_day":true}
        """#))
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        let first = result.findings[0], second = result.findings[1]
        #expect(first.start == nil && first.end == nil && first.remind == nil && first.due == nil)
        #expect(first.unresolved == ["start": "Wed 14 10:00", "end": "11:00", "remind": "15 min before"])
        #expect(second.unresolved == ["due": "Friday"] && second.allDay)
        #expect(first.provenance.isEmpty)
        #expect(first.timezone == TimeZone.current.identifier)
    }
}
