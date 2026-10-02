import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct PipelineCaseAnalyserTests {
    private let settings = ModelStepSettings(model: "m", think: .off, timeout: 60, modelThinks: false)

    private func golden(_ name: String = "calendar-week-outlook-24h-blocks") throws -> (GoldenCase, TempDirectory) {
        let temp = TempDirectory()
        try SyntheticCases.generate(into: temp.url)
        return (try GoldenCase.load(folder: temp.url.appendingPathComponent(name)), temp)
    }

    private func recogniserLines() -> [RecognisedLine] {
        [RecognisedLine(n: 1, text: "Team sync", box: PixelBox(x: 10, y: 20, width: 200, height: 18), confidence: 0.9),
         RecognisedLine(n: 2, text: "Mon 12", box: PixelBox(x: 10, y: 60, width: 100, height: 18), confidence: 0.8)]
    }

    private func makeModel(findings: String = #"{"findings":[{"kind":"appointment","title":"Team sync","cited_lines":[1],"start_text":"10:00"}]}"#) -> FakeModelChatting {
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer)
        model.answer(whenSchemaHas: "findings", findings)
        return model
    }

    private func longEdge(_ data: Data?) -> Int? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return max(image.width, image.height)
    }

    @Test func buildsTheInputTheWayTheQueueDoes() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        let recogniser = FakeTextRecogniser(lines: recogniserLines())
        let model = makeModel()
        let analyser = PipelineCaseAnalyser(recogniser: recogniser, model: model, settings: settings, size: 800, time: FakeTimeSource(1000))
        let result = try await analyser.analyse(golden, replaying: nil)

        #expect(recogniser.imageSizes.map { [$0.0, $0.1] } == [[1600, 1000]])
        let classify = try #require(model.requests(whereSchemaHas: "screen_kind").first)
        let extract = try #require(model.requests(whereSchemaHas: "findings").first)
        #expect(longEdge(classify.picture) == 800)          // never enlarged to 1024
        #expect(longEdge(extract.picture) == 800)
        #expect(extract.prompt.contains("L1 (0%,2%) Team sync"))
        #expect(result.kind == "calendar_week")
        #expect(result.findings.map(\.title) == ["Team sync"] && result.findings[0].citedLines == [1] && result.findings[0].citedText == "Team sync")
        #expect(result.lines.map(\.text) == ["Team sync", "Mon 12"] && result.lines[0].box == [10, 20, 200, 18])
        #expect(result.steps.map(\.step) == ["classify", "extract"])
        #expect(result.steps.allSatisfy { $0.rawAnswer != nil && !$0.request.contains("base64") })
    }

    @Test func theContextIsPickedFromTheCasesWindowsAndReportedByName() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        let other = ContextRecord(id: "other", name: "Customer Z", timezone: "Asia/Tokyo", hints: [ContextHint(kind: .windowTitle, value: "Customer Z")])
        let lines = recogniserLines() + [RecognisedLine(n: 3, text: "ana@customer-a.example", box: PixelBox(x: 10, y: 100, width: 200, height: 18), confidence: 0.9)]
        let analyser = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(lines: lines), model: makeModel(), settings: settings, size: 800,
                                            time: FakeTimeSource(1000), contexts: [other])
        let result = try await analyser.analyse(golden, replaying: nil)
        #expect(result.contextName == golden.expected.context && result.contextName == "Customer A")
        #expect(PipelineCaseAnalyser.contexts(in: [golden, golden]).map(\.name) == ["Customer A"])
    }

    @Test func aLargeSizeSendsTheClassificationAt1024() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        let model = makeModel()
        let analyser = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(lines: recogniserLines()), model: model, settings: settings, size: 1600,
                                            time: FakeTimeSource(1000))
        _ = try await analyser.analyse(golden, replaying: nil)
        #expect(longEdge(model.requests(whereSchemaHas: "screen_kind").first?.picture) == 1024)
        #expect(longEdge(model.requests(whereSchemaHas: "findings").first?.picture) == 1600)
    }

    @Test func replayingUsesTheStoredAnswersAndNeverCallsTheModel() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        let model = makeModel()
        let first = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(lines: recogniserLines()), model: model, settings: settings, size: 800,
                                         time: FakeTimeSource(1000))
        let original = try await first.analyse(golden, replaying: nil)
        let callsBefore = model.callCount

        let silent = FakeModelChatting()
        let again = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(lines: recogniserLines()), model: silent, settings: settings, size: 800,
                                         time: FakeTimeSource(1000))
        let replayed = try await again.analyse(golden, replaying: original.steps)
        #expect(silent.callCount == 0 && callsBefore == 2)
        #expect(replayed.kind == original.kind && replayed.findings == original.findings)
        #expect(replayed.steps.map(\.rawAnswer) == original.steps.map(\.rawAnswer))
    }

    @Test func aFailedAnalysisReturnsAFailedResultThatKeepsTheStepsMade() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        let model = makeModel(findings: #"{"findings":[{"kind":"task","title":"x"}]}"#)
        let analyser = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(lines: recogniserLines()), model: model, settings: settings, size: 800,
                                            time: FakeTimeSource(1000))
        let result = try await analyser.analyse(golden, replaying: nil)
        #expect(result.kind == "failed" && result.findings.isEmpty)
        #expect(result.steps.map(\.step) == ["classify", "extract"])
    }

    @Test func anUnreadablePictureIsAnError() async throws {
        let (golden, temp) = try golden(); defer { temp.cleanUp() }
        try Data("not a picture".utf8).write(to: golden.pictureURL)
        let analyser = PipelineCaseAnalyser(recogniser: FakeTextRecogniser(), model: FakeModelChatting(), settings: settings, size: 800,
                                            time: FakeTimeSource(1000))
        await #expect(throws: (any Error).self) { try await analyser.analyse(golden, replaying: nil) }
    }

    @Test func aWindowCaptureCaseIsAnalysedAsTheChosenWindow() async throws {
        let (golden, temp) = try golden("window-capture-terminal"); defer { temp.cleanUp() }
        let recogniser = FakeTextRecogniser(lines: recogniserLines())
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "windows", #"{"windows":[{"key":"w0","relevant":false,"kind":"other","confidence":0.8,"remote":false,"calendar_name":""}],"application":"Terminal","platform_look":"macos","theme":"dark","remote_session":{"is_remote":false,"client":""}}"#)
        model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        let analyser = PipelineCaseAnalyser(recogniser: recogniser, model: model, settings: settings, size: 800, time: FakeTimeSource(1000))
        let result = try await analyser.analyse(golden, replaying: nil)
        #expect(result.steps.map(\.step) == ["windows", "extract:w0"] && result.findings.isEmpty)
        #expect(model.requests(whereSchemaHas: "screen_kind").isEmpty)
    }
}
