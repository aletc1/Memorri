import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ModelTestJobTests {
    private static let goodAnswer = #"{"description":"A weekly calendar","contains_text":true,"text_sample":"Team sync 10:00"}"#

    private func chatReply(_ content: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return #"{"message":{"role":"assistant","content":\#(escaped)},"done":true,"done_reason":"stop","total_duration":1000000}"#
    }

    private struct Rig {
        let runner: ModelTestJobRunner
        let transport: FakeOllamaTransport
        let store: AnalysisStore
        let captures: CaptureStore
        let pictures: FakePictureProvider
        let settings: OllamaSettings
        let temp: TempDirectory
    }

    private func makeRig(model: String? = "qwen3.8:27b-mlx", tags: String? = nil) throws -> Rig {
        let temp = TempDirectory()
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        let transport = FakeOllamaTransport()
        transport.set("/api/version", .json(#"{"version":"0.34.4"}"#))
        transport.set("/api/tags", .json(tags ?? #"{"models":[{"name":"qwen3.8:27b-mlx","capabilities":["completion","vision","thinking"]}]}"#))
        transport.set("/api/chat", .json(chatReply(Self.goodAnswer)))
        let settings = OllamaSettings(store: FakeSettingsStore())
        settings.setModel(model)
        let time = FakeTimeSource(1000)
        let service = OllamaService(settings: settings, makeTransport: { _ in transport }, time: time)
        let store = AnalysisStore(database: database)
        let pictures = FakePictureProvider()
        let runner = ModelTestJobRunner(service: service, store: store, pictures: pictures, settings: settings, time: time)
        return Rig(runner: runner, transport: transport, store: store, captures: CaptureStore(database: database),
                   pictures: pictures, settings: settings, temp: temp)
    }

    /// A stored capture with a HEIC analysis copy, as spec 002 leaves it.
    private func addCapture(_ rig: Rig, id: String = "img-1") throws {
        let event = makeEventRecord()
        var image = makeImageRecord(eventID: event.id, id: id)
        image.modelWidth = 640; image.modelHeight = 270
        try rig.captures.insert(event: event, images: [image])
        rig.pictures.set(StoredPicture(data: makeHEICData(width: 640, height: 270), width: 640, height: 270), for: id)
    }

    private func job(_ rig: Rig, image: String? = "img-1") throws -> AnalysisJobRecord {
        let job = AnalysisJobRecord(imageId: image, createdAt: Date(timeIntervalSinceReferenceDate: 1000))
        try rig.store.enqueue(job)
        return job
    }

    // MARK: the job definition

    @Test func theSchemaAcceptsAKnownGoodAnswerAndRejectsOthers() {
        if case .failure = SchemaValidator.validate(Self.goodAnswer, against: ModelTestJob.schema) { Issue.record("good answer rejected") }
        if case .success = SchemaValidator.validate(#"{"description":"x"}"#, against: ModelTestJob.schema) { Issue.record("incomplete accepted") }
        #expect(ModelTestJob.promptVersion == "test-v1" && ModelTestJob.schemaVersion == "test-v1")
    }

    // MARK: outcomes and records

    @Test func aValidAnswerIsASuccessAndWritesASuccessRun() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        let item = try job(rig)
        #expect(await rig.runner.run(item, attempt: 1) == .success)
        let runs = try rig.store.runs()
        let run = try #require(runs.first)
        #expect(runs.count == 1 && run.outcome == "success" && run.failureReason == nil)
        #expect(run.model == "qwen3.8:27b-mlx" && run.think == "off" && run.temperature == 0)
        #expect(run.imageLongEdge == 640 && run.imageId == "img-1" && run.jobId == item.id && run.attempt == 1)
        #expect(run.promptVersion == "test-v1" && run.schemaVersion == "test-v1")
        #expect(run.durationMs >= 0)
        #expect(run.rawAnswer == Self.goodAnswer)
        #expect(run.requestJson.contains("[picture img-1 640x270]"))
        #expect(!run.requestJson.contains("/9j/"))                     // no base64 JPEG data
    }

    @Test func theRunRecordsTheChosenThinkSettingWhenTheModelThinks() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        rig.settings.setThink(.high)
        _ = await rig.runner.run(try job(rig), attempt: 1)
        #expect(try rig.store.runs().first?.think == "on")             // qwen only takes the boolean (ADR 0013)
        let body = try #require(rig.transport.requests(to: "/api/chat").first?.body)
        #expect(String(decoding: body, as: UTF8.self).contains(#""think":true"#))
    }

    @Test func theTimeoutComesFromTheSettingsAtTheStartOfEachAttempt() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        let item = try job(rig)
        #expect(rig.settings.setTimeoutSeconds(45))
        _ = await rig.runner.run(item, attempt: 1)
        #expect(rig.settings.setTimeoutSeconds(90))
        _ = await rig.runner.run(item, attempt: 2)
        #expect(rig.transport.requests(to: "/api/chat").map(\.timeout) == [45, 90])
    }

    @Test func anInvalidAnswerIsTransientAndKeepsTheRawAnswer() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        rig.transport.set("/api/chat", .json(chatReply("not json at all")))
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .transient("invalid answer"))
        let run = try #require(try rig.store.runs().first)
        #expect(run.outcome == "failed" && run.failureReason == "invalid answer" && run.rawAnswer == "not json at all")
    }

    @Test(arguments: [
        (FakeOllamaTransport.Reply.fail(.timedOut), JobOutcome.transient("timed out")),
        (FakeOllamaTransport.Reply.status(500), JobOutcome.transient("server error 500")),
        (FakeOllamaTransport.Reply.status(400), JobOutcome.permanent("request rejected")),
        (FakeOllamaTransport.Reply.fail(.unreachable), JobOutcome.serverUnavailable),
    ])
    func serverProblemsMapToOutcomes(reply: FakeOllamaTransport.Reply, expected: JobOutcome) async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        rig.transport.set("/api/chat", reply)
        #expect(await rig.runner.run(try job(rig), attempt: 1) == expected)
        if expected != .serverUnavailable {
            let run = try #require(try rig.store.runs().first)
            #expect(run.outcome == "failed" && run.rawAnswer == nil)
        }
    }

    @Test func aMissingPictureIsPermanentAndWritesNoRun() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        #expect(await rig.runner.run(try job(rig, image: "gone"), attempt: 1) == .permanent("picture no longer stored"))
        #expect(try rig.store.runs().isEmpty)
        #expect(rig.transport.requests(to: "/api/chat").isEmpty)
    }

    @Test func aCaptureDeletedBeforeTheRunIsWrittenFailsCleanly() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        // The provider still has the picture, but the capture row is gone, so the run cannot be stored.
        rig.pictures.set(StoredPicture(data: makeHEICData(width: 64, height: 64), width: 64, height: 64), for: "deleted")
        #expect(await rig.runner.run(try job(rig, image: "deleted"), attempt: 1) == .permanent("picture no longer stored"))
    }

    @Test func theStoredHEICIsSentAsJPEGButTheRunKeepsTheStoredSize() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let body = try #require(rig.transport.requests(to: "/api/chat").first?.body)
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: body),
              case .array(let messages)? = root["messages"], case .object(let message)? = messages.last,
              case .array(let images)? = message["images"], case .string(let base64)? = images.first,
              let picture = Data(base64Encoded: base64) else { Issue.record("no picture in the request"); return }
        #expect(picture.starts(with: [0xFF, 0xD8]))
        #expect(try rig.store.runs().first?.imageLongEdge == 640)
    }

    @Test func laterAttemptsResendTheIdenticalRequest() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        rig.transport.set("/api/chat", .json(chatReply("nope")))
        let item = try job(rig)
        for attempt in 1...3 { _ = await rig.runner.run(item, attempt: attempt) }
        let bodies = rig.transport.requests(to: "/api/chat").map { $0.body }
        #expect(bodies.count == 3 && bodies[0] == bodies[1] && bodies[1] == bodies[2])
        #expect(try rig.store.runs().map(\.attempt).sorted() == [1, 2, 3])
    }

    @Test func theRequestUsesTheNativeFormat() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        _ = await rig.runner.run(try job(rig), attempt: 1)
        let body = String(decoding: try #require(rig.transport.requests(to: "/api/chat").first?.body), as: UTF8.self)
        #expect(body.contains(#""format""#) && body.contains(#""temperature":0"#))
    }

    @Test func aJobWithoutAPictureUsesTheSample() async throws {
        let rig = try makeRig(); defer { rig.temp.cleanUp() }
        let item = try job(rig, image: nil)
        #expect(await rig.runner.run(item, attempt: 1) == .success)
        let run = try #require(try rig.store.runs().first)
        #expect(run.imageId == nil && run.imageLongEdge == 2048)
        #expect(run.requestJson.contains("[picture sample 2048x1152]"))
    }

    @Test func aChosenModelThatIsGoneMeansTheServerIsUnavailable() async throws {
        let rig = try makeRig(model: "gone:1b"); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .serverUnavailable)
        #expect(rig.transport.requests(to: "/api/chat").isEmpty)
    }

    @Test func noChosenModelMeansTheServerIsUnavailable() async throws {
        let rig = try makeRig(model: nil); defer { rig.temp.cleanUp() }
        try addCapture(rig)
        #expect(await rig.runner.run(try job(rig), attempt: 1) == .serverUnavailable)
    }
}
