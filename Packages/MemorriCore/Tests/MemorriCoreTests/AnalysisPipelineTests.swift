import CoreGraphics
import Foundation
import ImageIO
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
        #expect(step.promptVersion == "classify-v2")
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
        #expect(step.step == "extract" && step.promptVersion == "extract-calendar_week-v4" && step.schemaVersion == "schema-calendar_week-v1")
        #expect(result.findings.count == 1 && result.findings[0].title == "Team sync" && result.findings[0].citedLines == [1])
        #expect(result.findings[0].kind == .appointment && result.findings[0].confidence == 0.5)   // the end is guessed, so at most 0.5
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
                l(7, "13:00 - 14:30 Design review", x: 690, y: 400, w: 260), l(8, "Board room", x: 690, y: 425, w: 100)]
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

    // MARK: Contexts

    private let newYork = TimeZone(identifier: "America/New_York")!
    private func window(_ title: String, app: String = "Outlook") -> WindowInfo {
        WindowInfo(appName: app, bundleID: nil, title: title, frame: PixelBox(x: 0, y: 0, width: 800, height: 600))
    }
    private func context(_ id: String, zone: String?, titleHint: String) -> ContextRecord {
        ContextRecord(id: id, name: "Customer \(id)", timezone: zone, hints: [ContextHint(kind: .windowTitle, value: titleHint)])
    }

    /// "tomorrow" written at 22:30 in New York, which is already the 15th in UTC: the zone decides which day is meant.
    private func contextInput(contexts: [ContextRecord], windows: [WindowInfo], userChoice: ContextDecision? = nil) async throws -> AnalysisResult {
        let lines = [RecognisedLine(n: 1, text: "Send the report by tomorrow", box: PixelBox(x: 10, y: 10, width: 300, height: 18), confidence: 0.9)]
        let (rig, base) = dateInput(lines: lines)
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"Send the report","cited_lines":[1],"due_text":"tomorrow"}]}"#)
        let input = PipelineInput(image: base.image, classificationJPEG: base.classificationJPEG, classificationSize: base.classificationSize,
                                  analysisJPEG: base.analysisJPEG, analysisSize: base.analysisSize, macTimezone: TimeZone(identifier: "UTC")!,
                                  captureTime: SyntheticTime.date(2026, 10, 15, 2, 30, zone: "UTC"), locales: base.locales,
                                  contexts: contexts, windows: windows, userChoice: userChoice)
        return try await rig.pipeline.analyse(input, settings: settings)
    }

    @Test func aMatchedContextsZoneDecidesWhichDayTomorrowIs() async throws {
        let ny = context("A", zone: "America/New_York", titleHint: "Customer A")
        let result = try await contextInput(contexts: [ny, context("B", zone: "Asia/Tokyo", titleHint: "Customer B")], windows: [window("Inbox - Customer A - Outlook")])
        #expect(result.decision.contextID == "A" && result.decision.source == .auto)
        #expect(result.timezone == newYork && result.timezoneSource == "context")
        let finding = try #require(result.findings.first)
        #expect(finding.due == SyntheticTime.date(2026, 10, 15, zone: "America/New_York") && finding.timezone == "America/New_York")
    }

    @Test func withoutAContextTheMacsZoneIsUsed() async throws {
        let result = try await contextInput(contexts: [context("A", zone: "America/New_York", titleHint: "Customer A")], windows: [window("Something else")])
        #expect(result.decision == .unassigned && result.timezone == TimeZone(identifier: "UTC")! && result.timezoneSource == "mac")
        #expect(result.findings.first?.due == SyntheticTime.date(2026, 10, 16, zone: "UTC"))
    }

    @Test func aContextWithoutAZoneUsesTheMacsAndSaysSo() async throws {
        let result = try await contextInput(contexts: [context("A", zone: nil, titleHint: "Customer A")], windows: [window("Customer A")])
        #expect(result.decision.contextID == "A" && result.timezone == TimeZone(identifier: "UTC")! && result.timezoneSource == "mac")
    }

    @Test func anInvalidContextZoneFallsBackToTheMacsAndIsRecorded() async throws {
        let result = try await contextInput(contexts: [context("A", zone: "Mars/Olympus", titleHint: "Customer A")], windows: [window("Customer A")])
        #expect(result.decision.contextID == "A" && result.timezone == TimeZone(identifier: "UTC")! && result.timezoneSource == "invalid-context-zone")
    }

    @Test func aUserChoiceWinsOverWhatTheMatcherWouldPick() async throws {
        let a = context("A", zone: "America/New_York", titleHint: "Customer A"), b = context("B", zone: "Asia/Tokyo", titleHint: "Customer B")
        let choice = ContextDecision(contextID: "B", source: .user, score: 0)
        let result = try await contextInput(contexts: [a, b], windows: [window("Customer A")], userChoice: choice)
        #expect(result.decision == choice && result.timezone.identifier == "Asia/Tokyo" && result.timezoneSource == "context")
    }

    @Test func aUserChoiceOfUnassignedIsKeptToo() async throws {
        let choice = ContextDecision(contextID: nil, source: .user, score: 0)
        let result = try await contextInput(contexts: [context("A", zone: "America/New_York", titleHint: "Customer A")], windows: [window("Customer A")], userChoice: choice)
        #expect(result.decision == choice && result.timezone == TimeZone(identifier: "UTC")! && result.timezoneSource == "mac")
    }

    @Test func aUserChoiceOfAContextThatNoLongerExistsFallsBackToTheMacsZone() async throws {
        let choice = ContextDecision(contextID: "gone", source: .user, score: 0)
        let result = try await contextInput(contexts: [], windows: [], userChoice: choice)
        #expect(result.decision.source == .user && result.timezone == TimeZone(identifier: "UTC")! && result.timezoneSource == "mac")
    }

    // MARK: Tags

    @Test func theTagsComeFromTheCaptureTheTextAndTheFirstCall() async throws {
        let lines = [RecognisedLine(n: 1, text: "Wednesday 14", box: PixelBox(x: 10, y: 10, width: 120, height: 18), confidence: 0.9),
                     RecognisedLine(n: 2, text: "09:00 Budget meeting", box: PixelBox(x: 10, y: 60, width: 200, height: 18), confidence: 0.9),
                     RecognisedLine(n: 3, text: "13:30 Review", box: PixelBox(x: 10, y: 90, width: 200, height: 18), confidence: 0.9)]
        let (rig, base) = dateInput(lines: lines)
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        let input = PipelineInput(image: base.image, classificationJPEG: base.classificationJPEG, classificationSize: base.classificationSize,
                                  analysisJPEG: base.analysisJPEG, analysisSize: base.analysisSize, macTimezone: madrid, captureTime: captureTime,
                                  locales: base.locales, windows: [window("Inbox - Customer A - Outlook")], displayScale: 2)
        let tags = try await rig.pipeline.analyse(input, settings: settings).tags
        func value(_ key: String) -> String? { tags.first { $0.key == key }?.value }
        #expect(value("display_size") == "1600x1000" && value("display_scale") == "2x" && value("window_app") == "Outlook")
        #expect(value("clock_style") == "24h" && value("application") == "Outlook" && value("platform_look") == "windows" && value("theme") == "light")
        #expect(tags.first { $0.key == "application" }?.source == "visual" && tags.first { $0.key == "clock_style" }?.source == "code")
    }

    @Test func everyFindingCarriesTheTagsOfItsPicture() async throws {
        let plain = [RecognisedLine(n: 1, text: "Send the report by tomorrow", box: PixelBox(x: 10, y: 10, width: 300, height: 18), confidence: 0.9)]
        let (rig, input) = dateInput(lines: plain)
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"task","title":"A","cited_lines":[1],"due_text":"tomorrow"},{"kind":"task","title":"B","cited_lines":[1]}]}"#)
        let result = try await rig.pipeline.analyse(input, settings: settings)
        #expect(!result.tags.isEmpty && result.findings.count == 2)
        #expect(result.findings.allSatisfy { $0.tags == result.tags })
    }

    @Test func theLanguageOfThePictureDecidesWhatAnAmbiguousAbbreviationMeans() async throws {
        // "mar 13" is Tuesday 13 in Spanish and the 13th of March in English; the text around it is Spanish.
        let lines = [RecognisedLine(n: 1, text: "La reunión de presupuesto trimestral es el martes por la tarde", box: PixelBox(x: 10, y: 10, width: 600, height: 18), confidence: 0.9),
                     RecognisedLine(n: 2, text: "Por favor confirma si puedes asistir a la reunión con el equipo", box: PixelBox(x: 10, y: 40, width: 600, height: 18), confidence: 0.9),
                     RecognisedLine(n: 3, text: "mar 13 10:00 Revisión", box: PixelBox(x: 10, y: 70, width: 300, height: 18), confidence: 0.9)]
        let (rig, input) = dateInput(lines: lines)
        rig.model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer.replacingOccurrences(of: "calendar_week", with: "document"))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Revisión","cited_lines":[3],"start_text":"10:00","date_text":"mar 13"}]}"#)
        let result = try await rig.pipeline.analyse(input, settings: settings)
        #expect(result.tags.first { $0.key == "language" }?.value == "es")
        #expect(result.findings.first?.start == SyntheticTime.date(2026, 10, 13, 10, 0, zone: "Europe/Madrid"))
    }

    @Test func aMonthViewReadsEachEntrysDateFromItsCell() async throws {
        var lines: [RecognisedLine] = [RecognisedLine(n: 1, text: "October 2026", box: PixelBox(x: 20, y: 10, width: 200, height: 24), confidence: 0.9)]
        for (i, number) in (Array(28...30) + Array(1...31) + [1, 2]).enumerated() {
            lines.append(RecognisedLine(n: i + 2, text: "\(number)", box: PixelBox(x: (i % 7) * 200 + 10, y: 60 + (i / 7) * 150, width: 22, height: 18), confidence: 0.9))
        }
        lines.append(RecognisedLine(n: 38, text: "09:00 Budget meeting", box: PixelBox(x: 10, y: 60 + 150 + 30, width: 160, height: 18), confidence: 0.9))   // Monday 5
        lines.append(RecognisedLine(n: 39, text: "Training", box: PixelBox(x: 410, y: 60 + 3 * 150 + 30, width: 160, height: 18), confidence: 0.9))       // Wednesday 21
        let (rig, input) = dateInput(lines: lines)
        rig.model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer.replacingOccurrences(of: "calendar_week", with: "calendar_month"))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Budget meeting","cited_lines":[38],"start_text":"09:00"},{"kind":"appointment","title":"Training","cited_lines":[39],"all_day":true}]}"#)
        let result = try await rig.pipeline.analyse(input, settings: settings)
        #expect(result.findings[0].start == SyntheticTime.date(2026, 10, 5, 9, 0, zone: "Europe/Madrid"))
        #expect(result.findings[0].provenance["start"] == FieldProvenance(origin: .read, rule: "month-cell"))
        #expect(result.findings[1].start == SyntheticTime.date(2026, 10, 21, zone: "Europe/Madrid") && result.findings[1].allDay)
    }

    // MARK: Durations

    /// A drawn week view: headers, an hour scale and one block (`hours` long from 13:00 on Wednesday).
    private func weekPicture(hours: Double, title: String = "Design review", labels: Bool = true) throws -> (CGImage, [RecognisedLine]) {
        let canvas = SyntheticCanvas(width: 1600, height: 1000, background: RGB(0xFFFFFF))
        for (i, header) in ["Mon 12", "Tue 13", "Wed 14", "Thu 15", "Fri 16"].enumerated() { canvas.text(header, x: 110 + Double(i) * 300 + 10, y: 50, size: 18, color: RGB(0)) }
        if labels {
            for i in 0..<9 { canvas.text(String(format: "%02d:00", 9 + i), x: 12, y: 90 + Double(i) * 80 - 9, size: 18, color: RGB(0)) }
        }
        let top = 90 + 4 * 80.0 + 2          // 13:00
        canvas.fill(CGRect(x: 110 + 2 * 300 + 6, y: top, width: 288, height: hours * 80 - 4), RGB(0x1F73D9))
        canvas.text("13:00 \(title)", x: 110 + 2 * 300 + 18, y: top + 10, size: 20, color: RGB(0xFFFFFF))
        let source = CGImageSourceCreateWithData(try canvas.pngData() as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return (image, canvas.lines.enumerated().map { i, l in
            RecognisedLine(n: i + 1, text: l.text, box: PixelBox(x: l.box![0], y: l.box![1], width: l.box![2], height: l.box![3]), confidence: 0.9)
        })
    }

    private func durationRig(picture: (CGImage, [RecognisedLine]), kind: String = "calendar_week", findings: String) -> (Rig, PipelineInput) {
        let recogniser = FakeTextRecogniser(lines: picture.1)
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer.replacingOccurrences(of: "calendar_week", with: kind))
        model.answer(whenSchemaHas: "findings", findings)
        let rig = Rig(recogniser: recogniser, model: model, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: FakeTimeSource(1000)))
        let input = PipelineInput(image: picture.0, classificationJPEG: Data("c".utf8), classificationSize: (1024, 640), analysisJPEG: Data("a".utf8),
                                  analysisSize: (1600, 1000), macTimezone: madrid, captureTime: captureTime,
                                  locales: [Locale(identifier: "en_US"), Locale(identifier: "es_ES")])
        return (rig, input)
    }

    private func blockAnswer(end: String? = nil, extra: String = "") -> String {
        let endPart = end.map { #","end_text":"\#($0)""# } ?? ""
        return #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[15],"start_text":"13:00"\#(endPart)\#(extra)}]}"#
    }

    private func citedNumber(_ lines: [RecognisedLine], _ text: String) -> Int { lines.first { $0.text == text }!.n }

    private func endFinding(hours: Double = 1.5, labels: Bool = true, kind: String = "calendar_week", end: String? = nil, extra: String = "",
                            title: String = "Design review", alsoCite gutter: String? = nil) async throws -> Finding {
        let picture = try weekPicture(hours: hours, title: title, labels: labels)
        let number = citedNumber(picture.1, "13:00 \(title)")
        let cited = gutter.map { "\(number), \(citedNumber(picture.1, $0))" } ?? "\(number)"
        let answer = blockAnswer(end: end, extra: extra).replacingOccurrences(of: "[15]", with: "[\(cited)]")
        let (rig, input) = durationRig(picture: picture, kind: kind, findings: answer)
        return try #require(try await rig.pipeline.analyse(input, settings: settings).findings.first)
    }

    @Test func aWeekViewBlockWithoutAnEndGetsItFromItsHeight() async throws {
        for (hours, minutes) in [(0.5, 30), (1.0, 60), (1.5, 90), (2.0, 120)] {
            let finding = try await endFinding(hours: hours)
            let start = SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid")
            #expect(finding.end == start.addingTimeInterval(Double(minutes) * 60), Comment(rawValue: "\(minutes) minutes"))
            #expect(finding.provenance["end"] == FieldProvenance(origin: .inferred, rule: "block-height", reason: "block-height"))
            #expect(finding.confidence <= 0.5)
        }
    }

    @Test func withoutGeometryTheEndIsOneHourLater() async throws {
        let noScale = try await endFinding(hours: 1.5, labels: false)
        let start = SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid")
        #expect(noScale.end == start.addingTimeInterval(3600))
        #expect(noScale.provenance["end"] == FieldProvenance(origin: .inferred, rule: "default-60", reason: "default-60"))
        let email = try await endFinding(hours: 1.5, kind: "email")
        #expect(email.end == start.addingTimeInterval(3600) && email.provenance["end"]?.reason == "default-60")
    }

    @Test func anEndTakenFromTheHourScaleAtTheSideIsDroppedAndWorkedOutInstead() async throws {
        // The model cites the 15:00 label of the scale and reads it as the end; the block itself shows no end.
        let finding = try await endFinding(hours: 2, end: "15:00", alsoCite: "15:00")
        let start = SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid")
        #expect(finding.end == start.addingTimeInterval(7200), Comment(rawValue: "end \(String(describing: finding.end)) prov \(finding.provenance)"))
        #expect(finding.provenance["end"] == FieldProvenance(origin: .inferred, rule: "block-height", reason: "block-height"))
    }

    @Test func anEndThatIsNotWrittenAnywhereInTheCitedLinesIsDropped() async throws {
        let finding = try await endFinding(hours: 1, end: "14:15")
        #expect(finding.provenance["end"]?.origin == .inferred)
    }

    @Test func anEndAtOrBeforeTheStartIsDropped() async throws {
        let finding = try await endFinding(hours: 1, end: "13:00", title: "Design review until 13:00")
        let start = SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid")
        #expect(finding.end == start.addingTimeInterval(3600) && finding.provenance["end"]?.origin == .inferred)
    }

    @Test func aHeaderCitedAlongsideTheBlockIsNotTakenForTheBlock() async throws {
        // The model cites the date header as well; its line is above the block and would measure nothing or the wrong thing.
        let finding = try await endFinding(hours: 1, alsoCite: "Wed 14")
        let start = SyntheticTime.date(2026, 10, 14, 13, 0, zone: "Europe/Madrid")
        #expect(finding.end == start.addingTimeInterval(3600) && finding.provenance["end"]?.rule == "block-height")
    }

    @Test func anExplicitEndIsReadAndNotFlagged() async throws {
        let finding = try await endFinding(hours: 2, end: "14:15", title: "Design review - 14:15")
        #expect(finding.end == SyntheticTime.date(2026, 10, 14, 14, 15, zone: "Europe/Madrid"))
        #expect(finding.provenance["end"]?.origin == .read)
        #expect(!finding.provenance.values.contains { $0.origin == .inferred })
    }

    @Test func anEndThatWouldPassMidnightIsCutAtTheEndOfTheDay() async throws {
        let plain = [RecognisedLine(n: 1, text: "Late call", box: PixelBox(x: 10, y: 10, width: 100, height: 18), confidence: 0.9)]
        let (rig, input) = durationRig(picture: (makeTestImage(width: 1600, height: 1000), plain), kind: "document",
                                       findings: #"{"findings":[{"kind":"appointment","title":"Late call","cited_lines":[1],"start_text":"Oct 14 23:30"}]}"#)
        let finding = try #require(try await rig.pipeline.analyse(input, settings: settings).findings.first)
        #expect(finding.end == SyntheticTime.date(2026, 10, 15, 0, 0, zone: "Europe/Madrid"))
        #expect(finding.provenance["end"] == FieldProvenance(origin: .inferred, rule: "end-of-day", reason: "end-of-day"))
    }

    @Test func tasksDeadlinesAllDayAppointmentsAndUnresolvedStartsGetNoEnd() async throws {
        let plain = [RecognisedLine(n: 1, text: "text", box: PixelBox(x: 10, y: 10, width: 100, height: 18), confidence: 0.9)]
        let (rig, input) = durationRig(picture: (makeTestImage(width: 1600, height: 1000), plain), kind: "document", findings: #"""
        {"findings":[{"kind":"task","title":"Task","cited_lines":[1],"due_text":"Friday"},
                     {"kind":"deadline","title":"Submit it","cited_lines":[1],"due_text":"2026-11-06"},
                     {"kind":"appointment","title":"Conference","cited_lines":[1],"date_text":"Oct 20","all_day":true},
                     {"kind":"appointment","title":"Vague","cited_lines":[1],"start_text":"sometime"}]}
        """#)
        let findings = try await rig.pipeline.analyse(input, settings: settings).findings
        #expect(findings.count == 4 && findings.allSatisfy { $0.end == nil && $0.provenance["end"] == nil })
    }
}
