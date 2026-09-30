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

    // MARK: Dates

    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private var captureTime: Date { SyntheticTime.date(2026, 10, 14, 9, 12, zone: "Europe/Madrid") }

    private func dateInput(lines: [RecognisedLine]) -> (Rig, PipelineInput) {
        let recogniser = FakeTextRecogniser(lines: lines)
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer)
        let rig = Rig(recogniser: recogniser, model: model, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: FakeTimeSource(1000)))
        let input = PipelineInput(image: makeTestImage(width: 1600, height: 1000), classificationJPEG: Data("c".utf8), classificationSize: (1024, 640),
                                  analysisJPEG: Data("a".utf8), analysisSize: (1600, 1000), macTimezone: madrid, captureTime: captureTime,
                                  locales: [Locale(identifier: "en_US"), Locale(identifier: "es_ES")])
        return (rig, input)
    }

    private func weekLines() -> [RecognisedLine] {
        func l(_ n: Int, _ text: String, x: Int, y: Int, w: Int = 80) -> RecognisedLine {
            RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: 18), confidence: 0.9)
        }
        return [l(1, "October 12 – 16, 2026", x: 20, y: 20, w: 300), l(2, "Mon 12", x: 100, y: 100), l(3, "Tue 13", x: 400, y: 100), l(4, "Wed 14", x: 700, y: 100),
                l(5, "Thu 15", x: 1000, y: 100), l(6, "Fri 16", x: 1300, y: 100),
                l(7, "13:00 Design review", x: 690, y: 400, w: 200), l(8, "Board room", x: 690, y: 425, w: 100)]
    }

    @Test func weekViewHeadersGiveEachBlockItsDateWithTheRuleRecorded() async throws {
        let (rig, input) = dateInput(lines: weekLines())
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[7,8],"start_text":"13:00","end_text":"14:30"}]}"#)
        let result = try await rig.pipeline.analyse(input, settings: settings)
        let finding = try #require(result.findings.first)
        #expect(finding.start == SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid"))
        #expect(finding.end == SyntheticTime.date(2026, 10, 14, 14, 30, zone: "Europe/Madrid"))
        #expect(finding.provenance["start"] == FieldProvenance(origin: .read, rule: "header-column"))
        #expect(finding.provenance["end"] == FieldProvenance(origin: .read, rule: "header-column"))
        #expect(finding.unresolved.isEmpty && !finding.allDay && finding.timezone == "Europe/Madrid" && finding.confidence == 0.9)
        #expect(result.timezone == madrid && result.timezoneSource == "mac")
    }

    @Test func theColumnLineOfTheModelPicksTheHeader() async throws {
        let (rig, input) = dateInput(lines: weekLines())
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[7],"start_text":"13:00","column_line":6}]}"#)
        let finding = try #require(try await rig.pipeline.analyse(input, settings: settings).findings.first)
        #expect(finding.start == SyntheticTime.date(2026, 10, 16, 13, 0, zone: "Europe/Madrid"))
    }

    @Test func wordsAreResolvedAgainstTheCaptureAndUnreadableTextsStayAsWritten() async throws {
        let plain = [RecognisedLine(n: 1, text: "Send the report by tomorrow", box: PixelBox(x: 10, y: 10, width: 300, height: 18), confidence: 0.9)]
        let (rig, input) = dateInput(lines: plain)
        rig.model.answer(whenSchemaHas: "findings", #"""
        {"findings":[{"kind":"task","title":"Send the report","cited_lines":[1],"due_text":"tomorrow"},
                     {"kind":"task","title":"Vague","cited_lines":[1],"due_text":"sometime soon","remind_text":"15 min before"}]}
        """#)
        let result = try await rig.pipeline.analyse(input, settings: settings)
        let first = result.findings[0], second = result.findings[1]
        #expect(first.due == SyntheticTime.date(2026, 10, 15, zone: "Europe/Madrid") && first.allDay)
        #expect(first.provenance["due"] == FieldProvenance(origin: .read, rule: "relative-day") && first.unresolved.isEmpty)
        #expect(second.due == nil && second.remind == nil && second.unresolved == ["due": "sometime soon", "remind": "15 min before"])
        #expect(second.provenance.isEmpty)
    }

    @Test func aDeadlineWithAnActionGetsAnInferredReminderAndLowerConfidence() async throws {
        let plain = [RecognisedLine(n: 1, text: "Submit the grant proposal by 2026-11-06", box: PixelBox(x: 10, y: 10, width: 300, height: 18), confidence: 0.95)]
        let (rig, input) = dateInput(lines: plain)
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"deadline","title":"Submit the grant proposal","cited_lines":[1],"due_text":"2026-11-06"}]}"#)
        let finding = try #require(try await rig.pipeline.analyse(input, settings: settings).findings.first)
        #expect(finding.due == SyntheticTime.date(2026, 11, 6, zone: "Europe/Madrid"))
        #expect(finding.remind == SyntheticTime.date(2026, 11, 5, 9, 0, zone: "Europe/Madrid"))
        #expect(finding.provenance["remind"] == FieldProvenance(origin: .inferred, rule: "deadline-reminder"))
        #expect(finding.confidence == 0.5)
    }

    @Test func anEmailsSentDateIsTheReferenceForItsWords() async throws {
        let plain = [RecognisedLine(n: 1, text: "Please send me the report by tomorrow", box: PixelBox(x: 10, y: 10, width: 300, height: 18), confidence: 0.9)]
        let (rig, input) = dateInput(lines: plain)
        rig.model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer.replacingOccurrences(of: "calendar_week", with: "email"))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"Send the report","cited_lines":[1],"due_text":"tomorrow","sent_text":"Mon 12 Oct 2026 09:12"}]}"#)
        let finding = try #require(try await rig.pipeline.analyse(input, settings: settings).findings.first)
        #expect(finding.due == SyntheticTime.date(2026, 10, 13, zone: "Europe/Madrid"))
    }
}
