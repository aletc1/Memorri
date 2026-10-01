import Foundation
import Testing
@testable import MemorriCore

@Suite struct LiveMeaningJudgeTests {
    private func rig(installed: [String]) -> (LiveMeaningJudge, OllamaSettings, FakeOllamaTransport, FakeTimeSource) {
        let transport = FakeOllamaTransport()
        let models = installed.map { #"{"name":"\#($0)","capabilities":["completion"]}"# }.joined(separator: ",")
        transport.set("/api/tags", .json(#"{"models":[\#(models)]}"#))
        transport.set("/api/embed", .json(#"{"embeddings":[[1,0]]}"#))
        let settings = OllamaSettings(store: FakeSettingsStore())
        let time = FakeTimeSource(1000)
        let service = OllamaService(settings: settings, makeTransport: { _ in transport }, time: time)
        return (LiveMeaningJudge(service: service, settings: settings, database: nil, time: time), settings, transport, time)
    }

    private let both = [OllamaSettings.defaultEmbeddingModel, OllamaSettings.defaultRerankerModel]

    @Test func theDefaultModelsAreUsedWhenInstalled() async throws {
        let (judge, _, transport, _) = rig(installed: both)
        let embed = await judge.canEmbed, rerank = await judge.canJudge
        #expect(embed && rerank)
        let vectors = try await judge.embeddings(for: ["daily standup"])
        #expect(vectors == [[1, 0]])
        let sent = try #require(transport.requests(to: "/api/embed").first)
        let data = try #require(sent.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == OllamaSettings.defaultEmbeddingModel)
    }

    @Test func withoutTheModelsInstalledNothingIsAvailable() async {
        let (judge, _, _, _) = rig(installed: ["qwen3-vl:8b-instruct"])
        let embed = await judge.canEmbed, rerank = await judge.canJudge
        #expect(!embed && !rerank)
    }

    @Test func choosingNoneTurnsAModelOff() async {
        let (judge, settings, _, time) = rig(installed: both)
        settings.setRerankerModel(nil)
        time.set(1000 + 61)
        let embed = await judge.canEmbed, rerank = await judge.canJudge
        #expect(embed && !rerank)
    }

    @Test func aChangeOfSettingsIsPickedUpWithinAMinuteAndAtOnceForTheChoice() async {
        let (judge, settings, _, time) = rig(installed: both + ["my-embedder:1"])
        let first = await judge.canEmbed
        #expect(first)
        settings.setEmbeddingModel(nil)
        // the choice is part of the cache key, so it takes effect at once
        let after = await judge.canEmbed
        #expect(!after)
        settings.setEmbeddingModel("my-embedder:1")
        time.set(2000)
        let again = await judge.canEmbed
        #expect(again)
    }

    @Test func aServerThatCannotBeAskedMeansUnavailable() async {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .fail(.unreachable))
        let settings = OllamaSettings(store: FakeSettingsStore())
        let time = FakeTimeSource(0)
        let judge = LiveMeaningJudge(service: OllamaService(settings: settings, makeTransport: { _ in transport }, time: time),
                                     settings: settings, database: nil, time: time)
        let embed = await judge.canEmbed, rerank = await judge.canJudge
        #expect(!embed && !rerank)
        await #expect(throws: MeaningJudgeError.unavailable) { _ = try await judge.embeddings(for: ["a"]) }
    }
}
