import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import MemorriCore

@Suite struct ModelStepTests {
    private static let goodAnswer = #"{"description":"A weekly calendar","contains_text":true,"text_sample":"Team sync"}"#
    private static let tagsWithThinking = #"{"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision","thinking"]}]}"#

    private func reply(_ content: String, thinking: String? = nil) -> String {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        let think = thinking.map { #","thinking":\#(String(data: try! JSONEncoder().encode($0), encoding: .utf8)!)"# } ?? ""
        return #"{"message":{"role":"assistant","content":\#(escaped)\#(think)},"done":true,"done_reason":"stop"}"#
    }

    private struct Rig {
        let transport: FakeOllamaTransport
        let service: OllamaService
        let settings: OllamaSettings
        var client: OllamaClient { OllamaClient(transport: transport) }
    }

    private func makeRig(model: String? = "qwen3.8:27b-mlx", tags: String = tagsWithThinking) -> Rig {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .json(tags))
        transport.set("/api/chat", .json(reply(Self.goodAnswer)))
        let settings = OllamaSettings(store: FakeSettingsStore())
        settings.setModel(model)
        let service = OllamaService(settings: settings, makeTransport: { _ in transport }, time: FakeTimeSource(0))
        return Rig(transport: transport, service: service, settings: settings)
    }

    private func call(_ rig: Rig, settings: ModelStepSettings? = nil) async throws -> Result<ModelStepResult, ModelStepFailure> {
        let resolved: ModelStepSettings
        if let settings { resolved = settings } else {
            switch await ModelStep.settings(service: rig.service, settings: rig.settings) {
            case .success(let value): resolved = value
            case .failure(let error): Issue.record("settings failed: \(error)"); throw error
            }
        }
        return await ModelStep.call(using: rig.client, settings: resolved, step: "classify", prompt: "Describe.",
                                    picture: Data([0xFF, 0xD8, 0x01, 0x02]), placeholder: "[picture img-1 640x270]",
                                    schema: ModelTestJob.schema, promptVersion: "p-v1", schemaVersion: "s-v1")
    }

    // MARK: settings

    @Test func settingsAreReadFromTheSettingsAndTheModelList() async {
        let rig = makeRig()
        rig.settings.setThink(.high)
        #expect(rig.settings.setTimeoutSeconds(120))
        guard case .success(let value) = await ModelStep.settings(service: rig.service, settings: rig.settings) else {
            Issue.record("expected settings"); return
        }
        #expect(value == ModelStepSettings(model: "qwen3.8:27b-mlx", think: .high, timeout: 120, modelThinks: true))
    }

    @Test func noChosenModelOrAMissingOneMeansServerUnavailable() async {
        let none = makeRig(model: nil)
        #expect(await ModelStep.settings(service: none.service, settings: none.settings).isFailure(.serverUnavailable))
        let gone = makeRig(model: "gone:1b")
        #expect(await ModelStep.settings(service: gone.service, settings: gone.settings).isFailure(.serverUnavailable))
    }

    @Test func aModelThatCannotReadImagesMeansServerUnavailable() async {
        let rig = makeRig(tags: #"{"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion"]}]}"#)
        #expect(await ModelStep.settings(service: rig.service, settings: rig.settings).isFailure(.serverUnavailable))
    }

    @Test func listProblemsMapLikeChatProblems() async {
        let down = makeRig(); down.transport.set("/api/tags", .fail(.unreachable))
        #expect(await ModelStep.settings(service: down.service, settings: down.settings).isFailure(.serverUnavailable))
        let slow = makeRig(); slow.transport.set("/api/tags", .fail(.timedOut))
        #expect(await ModelStep.settings(service: slow.service, settings: slow.settings).isFailure(.transient("timed out")))
    }

    // MARK: the call

    @Test func aValidAnswerIsParsedAndRecordedWithoutPictureData() async throws {
        let rig = makeRig()
        guard case .success(let result) = try await call(rig) else { Issue.record("expected success"); return }
        if case .object(let fields) = result.value, case .string(let text)? = fields["text_sample"] { #expect(text == "Team sync") } else { Issue.record("not parsed") }
        #expect(result.record.step == "classify" && result.record.failure == nil)
        #expect(result.record.rawAnswer == Self.goodAnswer)
        #expect(result.record.request.contains("[picture img-1 640x270]"))
        #expect(!result.record.request.contains("/9j/") && !result.record.request.contains("/9g"))   // no base64 of the picture
        #expect(result.record.model == "qwen3.8:27b-mlx" && result.record.think == "off")
        #expect(result.record.promptVersion == "p-v1" && result.record.schemaVersion == "s-v1")
        #expect(result.record.durationMs >= 0)
    }

    @Test func theRequestUsesTheNativeFormatTemperatureZeroAndTheSettingsTimeout() async throws {
        let rig = makeRig()
        #expect(rig.settings.setTimeoutSeconds(75))
        _ = try await call(rig)
        let request = try #require(rig.transport.requests(to: "/api/chat").first)
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.contains(#""format""#) && body.contains(#""temperature":0"#))
        #expect(request.timeout == 75)
        #expect(body.contains(#""think":false"#))
    }

    @Test func thinkingTextIsKeptAfterTheAnswer() async throws {
        let rig = makeRig()
        rig.transport.set("/api/chat", .json(reply(Self.goodAnswer, thinking: "Let me look.")))
        rig.settings.setThink(.low)
        guard case .success(let result) = try await call(rig) else { Issue.record("expected success"); return }
        #expect(result.record.rawAnswer == Self.goodAnswer + ModelTestJob.thinkingMarker + "Let me look.")
        #expect(result.record.think == "on")
    }

    @Test(arguments: [
        (FakeOllamaTransport.Reply.fail(.timedOut), PipelineError.transient("timed out")),
        (FakeOllamaTransport.Reply.status(500), PipelineError.transient("server error 500")),
        (FakeOllamaTransport.Reply.status(400), PipelineError.permanent("request rejected")),
        (FakeOllamaTransport.Reply.fail(.unreachable), PipelineError.serverUnavailable),
    ])
    func clientErrorsMapLikeTheTestJob(replyValue: FakeOllamaTransport.Reply, expected: PipelineError) async throws {
        let rig = makeRig()
        rig.transport.set("/api/chat", replyValue)
        guard case .failure(let failure) = try await call(rig) else { Issue.record("expected failure"); return }
        #expect(failure.error == expected)
        #expect(failure.record.rawAnswer == nil)
    }

    @Test func anAnswerThatDoesNotMatchTheSchemaIsTransientAndKeepsItsRawText() async throws {
        let rig = makeRig()
        rig.transport.set("/api/chat", .json(reply("not json at all")))
        guard case .failure(let failure) = try await call(rig) else { Issue.record("expected failure"); return }
        #expect(failure.error == .transient("invalid answer"))
        #expect(failure.record.rawAnswer == "not json at all" && failure.record.failure == "invalid answer")
    }

    @Test func aModelWithoutThinkingGetsNoThinkField() async throws {
        let rig = makeRig(tags: #"{"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision"]}]}"#)
        rig.settings.setThink(.high)
        _ = try await call(rig)
        let body = String(decoding: try #require(rig.transport.requests(to: "/api/chat").first?.body), as: UTF8.self)
        #expect(!body.contains(#""think""#))
    }

    // MARK: pictures

    @Test func aPictureCanBeScaledDownToAGivenLongerSide() throws {
        let heic = makeHEICData(width: 640, height: 270)
        let jpeg = try PictureConverter.jpegData(from: heic, longEdge: 320)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 135)
    }

    @Test func aPictureIsNeverScaledUp() throws {
        let heic = makeHEICData(width: 200, height: 100)
        let jpeg = try PictureConverter.jpegData(from: heic, longEdge: 1024)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 200 && image.height == 100)
    }
}

private extension Result where Failure == PipelineError {
    func isFailure(_ expected: PipelineError) -> Bool {
        if case .failure(let error) = self { return error == expected }
        return false
    }
}
