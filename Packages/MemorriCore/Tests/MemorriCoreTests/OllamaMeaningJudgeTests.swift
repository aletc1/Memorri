import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct OllamaMeaningJudgeTests {
    private let tags = #"{"models":[{"name":"e5:1","capabilities":["completion"]},{"name":"rr:1","capabilities":["completion"]}]}"#
    private let a = JudgedSighting(title: "Daily standup", when: "Tue 14 Oct 09:00-09:15", context: "Customer A")
    private let b = JudgedSighting(title: "Reunión diaria", when: "Tue 14 Oct 09:00-09:15", context: nil)

    private func judge(_ transport: FakeOllamaTransport, embedding: String? = "e5:1", reranker: String? = "rr:1",
                       database: StorageDatabase? = nil) -> OllamaMeaningJudge {
        transport.set("/api/tags", .json(tags))
        return OllamaMeaningJudge(client: OllamaClient(transport: transport), embeddingModel: embedding, rerankerModel: reranker,
                                  database: database, now: { Date(timeIntervalSince1970: 0) })
    }

    private func body(_ request: OllamaHTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func embeddingsSendTheTitlesPrefixedInOneBatch() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/embed", .json(#"{"embeddings":[[1,0],[0,1]]}"#))
        let vectors = try await judge(transport).embeddings(for: ["daily standup", "design review"])
        #expect(vectors == [[1, 0], [0, 1]])
        let sent = transport.requests(to: "/api/embed")
        #expect(sent.count == 1)
        let fields = try body(sent[0])
        #expect(fields["input"] as? [String] == ["query: daily standup", "query: design review"])
        #expect(fields["model"] as? String == "e5:1")
    }

    @Test func rerankerPromptHoldsBothTitlesTimesAndContext() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/generate", .json(#"{"logprobs":[{"token":"yes","logprob":-0.2,"top_logprobs":[{"token":"yes","logprob":-0.2},{"token":"no","logprob":-1.9}]}]}"#))
        _ = try await judge(transport).sameEvent(a, b)
        let sent = try #require(transport.requests(to: "/api/generate").first)
        let fields = try body(sent)
        let prompt = try #require(fields["prompt"] as? String)
        #expect(prompt.hasPrefix("<|im_start|>system\nJudge whether the Document meets the requirements"))
        #expect(prompt.contains("<Instruct>: Are these two entries the same event"))
        #expect(prompt.contains("Two different topics at the same time are different events."))
        #expect(prompt.contains("<Query>: Daily standup, Tue 14 Oct 09:00-09:15, Customer A\n"))
        #expect(prompt.contains("<Document>: Reunión diaria, Tue 14 Oct 09:00-09:15<|im_end|>"))
        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(fields["model"] as? String == "rr:1")
        #expect(OllamaMeaningJudge.instructionVersion == "rerank-v2")
    }

    @Test func bothOrdersAreAskedAndTheLowerProbabilityCounts() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/generate", .json(#"{"logprobs":[{"token":"yes","logprob":-0.2,"top_logprobs":[{"token":"yes","logprob":-0.2},{"token":"no","logprob":-1.9}]}]}"#))
        _ = try await judge(transport).sameEvent(a, b)
        let sent = transport.requests(to: "/api/generate")
        #expect(sent.count == 2)
        let first = try #require(try body(sent[0])["prompt"] as? String), second = try #require(try body(sent[1])["prompt"] as? String)
        #expect(first.contains("<Query>: Daily standup") && first.contains("<Document>: Reunión diaria"))
        #expect(second.contains("<Query>: Reunión diaria") && second.contains("<Document>: Daily standup"))
    }

    @Test func probabilityOfYesSumsCaseVariantsAgainstNo() async throws {
        let transport = FakeOllamaTransport()
        // yes 0.5 + Yes 0.1 = 0.6 against no 0.2 + No 0.1 = 0.3  ->  0.6 / 0.9
        let answer = """
        {"logprobs":[{"token":"yes","logprob":\(log(0.5)),"top_logprobs":[{"token":"yes","logprob":\(log(0.5))},{"token":"Yes","logprob":\(log(0.1))},
        {"token":"no","logprob":\(log(0.2))},{"token":"No","logprob":\(log(0.1))},{"token":"maybe","logprob":-5}]}]}
        """
        transport.set("/api/generate", .json(answer))
        let p = try await judge(transport).sameEvent(a, b)
        #expect(abs(p - 0.6 / 0.9) < 1e-9)
    }

    @Test func anAnswerWithNeitherYesNorNoThrows() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/generate", .json(#"{"logprobs":[{"token":"x","logprob":-1,"top_logprobs":[{"token":"maybe","logprob":-1}]}]}"#))
        await #expect(throws: MeaningJudgeError.badAnswer) { _ = try await judge(transport).sameEvent(a, b) }
        let bare = FakeOllamaTransport()
        bare.set("/api/generate", .json(#"{"response":"yes"}"#))
        await #expect(throws: (any Error).self) { _ = try await judge(bare).sameEvent(a, b) }
    }

    @Test func availabilityFollowsTheChosenAndInstalledModels() async throws {
        let transport = FakeOllamaTransport()
        let both = judge(transport)
        let bothEmbed = await both.canEmbed, bothJudge = await both.canJudge
        #expect(bothEmbed && bothJudge)
        let noReranker = judge(FakeOllamaTransport(), reranker: nil)
        let noRerankerEmbed = await noReranker.canEmbed, noRerankerJudge = await noReranker.canJudge
        #expect(noRerankerEmbed)
        #expect(noRerankerJudge == false)
        let missing = judge(FakeOllamaTransport(), embedding: "not-installed:1")
        let missingEmbed = await missing.canEmbed, missingJudge = await missing.canJudge
        #expect(missingEmbed == false)
        #expect(missingJudge)
        let none = judge(FakeOllamaTransport(), embedding: nil, reranker: nil)
        let noneEmbed = await none.canEmbed, noneJudge = await none.canJudge
        #expect(noneEmbed == false && noneJudge == false)
    }

    @Test func availabilityIsFalseWhenTheServerCannotBeAsked() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .fail(.unreachable))
        let judge = OllamaMeaningJudge(client: OllamaClient(transport: transport), embeddingModel: "e5:1", rerankerModel: "rr:1",
                                       database: nil, now: { Date(timeIntervalSince1970: 0) })
        let embed = await judge.canEmbed, judges = await judge.canJudge
        #expect(embed == false && judges == false)
    }

    @Test func callsWithoutAModelThrowUnavailable() async throws {
        let none = judge(FakeOllamaTransport(), embedding: nil, reranker: nil)
        await #expect(throws: MeaningJudgeError.unavailable) { _ = try await none.embeddings(for: ["a"]) }
        await #expect(throws: MeaningJudgeError.unavailable) { _ = try await none.sameEvent(a, b) }
        await #expect(throws: MeaningJudgeError.unavailable) { _ = try await NoMeaningJudge().embeddings(for: ["a"]) }
        await #expect(throws: MeaningJudgeError.unavailable) { _ = try await NoMeaningJudge().sameEvent(a, b) }
        let embed = await NoMeaningJudge().canEmbed, judges = await NoMeaningJudge().canJudge
        #expect(embed == false && judges == false)
    }

    @Test func embeddingsAreCachedInTheDatabaseByTitleAndModel() async throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let transport = FakeOllamaTransport()
        transport.set("/api/embed", .json(#"{"embeddings":[[1,2,3]]}"#))
        let judge = judge(transport, database: fixture.database)
        _ = try await judge.embeddings(for: ["daily standup"])
        let again = try await judge.embeddings(for: ["daily standup"])
        #expect(again == [[1, 2, 3]])
        #expect(transport.requests(to: "/api/embed").count == 1)
        // only the missing titles are sent, and the answer keeps the order of the request
        transport.set("/api/embed", .json(#"{"embeddings":[[4,5,6]]}"#))
        let mixed = try await judge.embeddings(for: ["design review", "daily standup"])
        #expect(mixed == [[4, 5, 6], [1, 2, 3]])
        let secondBody = try body(transport.requests(to: "/api/embed")[1])
        #expect(secondBody["input"] as? [String] == ["query: design review"])
        let stored = try await fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM title_embeddings WHERE model = 'e5:1'") }
        #expect(stored == 2)
    }
}
