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
        return Rig(recogniser: recogniser, model: model, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: FakeTimeSource(1000)))
    }

    private func input(reuse: PipelineInput.Reuse = .init()) -> PipelineInput {
        PipelineInput(image: makeTestImage(width: 1200, height: 600), classificationJPEG: Data("jpeg-bytes".utf8),
                      classificationSize: (1024, 512), reuse: reuse)
    }

    @Test func aRunReadsThePictureAndAsksOnceForTheKind() async throws {
        let rig = makeRig()
        let result = try await rig.pipeline.analyse(input(), settings: settings)
        #expect(rig.recogniser.callCount == 1)
        #expect(rig.model.callCount == 1)
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
        #expect(result.steps.count == 1 && step.step == "classify")
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

    @Test func aResumedRunWithStoredLinesAndKindCallsNothing() async throws {
        let rig = makeRig()
        let stored = try #require(ClassificationResult.parse(storedAnswer: ClassificationTests.goodAnswer))
        let result = try await rig.pipeline.analyse(input(reuse: .init(lines: lines(), classification: stored)), settings: settings)
        #expect(rig.recogniser.callCount == 0 && rig.model.callCount == 0)
        #expect(result.lines == lines() && result.classification.kind == .calendarWeek && result.steps.isEmpty)
    }

    @Test func aResumedRunWithOnlyStoredLinesStillAsksForTheKind() async throws {
        let rig = makeRig()
        _ = try await rig.pipeline.analyse(input(reuse: .init(lines: lines(), classification: nil)), settings: settings)
        #expect(rig.recogniser.callCount == 0 && rig.model.callCount == 1)
    }
}
