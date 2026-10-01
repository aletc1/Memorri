import Foundation
import Testing
@testable import MemorriCore

@Suite struct OllamaClientTests {
    private let testSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["description": .object(["type": .string("string")])]),
        "required": .array([.string("description")]),
    ])
    private let picture = Data(repeating: 0xAB, count: 600)          // base64 is a long run of "q"
    private var base64: String { picture.base64EncodedString() }

    private func chatRequest(think: ThinkWireValue = .bool(false), native: Bool = true, timeout: TimeInterval = 300) -> ChatRequest {
        ChatRequest(model: "qwen3.8:27b-mlx", systemPrompt: nil, prompt: "Describe it.", picture: picture,
                    picturePlaceholder: "[picture abc 2048x857]", schema: testSchema, useNativeFormat: native,
                    think: think, temperature: 0, timeout: timeout)
    }

    @Test func aLengthLimitIsSentAsNumPredictAndOtherwiseNothingIsLimited() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/chat", .json(chatAnswer))
        var limited = chatRequest()
        limited = ChatRequest(model: limited.model, systemPrompt: nil, prompt: limited.prompt, picture: picture, picturePlaceholder: limited.picturePlaceholder,
                              schema: testSchema, useNativeFormat: true, think: .bool(false), temperature: 0, timeout: 60, maxTokens: 1500)
        _ = try await OllamaClient(transport: transport).chat(limited)
        _ = try await OllamaClient(transport: transport).chat(chatRequest())
        let sent = transport.requests(to: "/api/chat")
        #expect((try body(of: sent[0])["options"] as? [String: Any])?["num_predict"] as? Int == 1500)
        #expect((try body(of: sent[1])["options"] as? [String: Any])?["num_predict"] == nil)
    }

    private func body(of request: OllamaHTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let chatAnswer = """
    {"model":"m","message":{"role":"assistant","content":"{\\"description\\":\\"x\\"}","thinking":"hmm"},
     "done":true,"done_reason":"stop","total_duration":4883583458,"load_duration":1334875,
     "prompt_eval_duration":342546000,"eval_count":282}
    """

    // MARK: version and models

    @Test func versionReadsApiVersion() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/version", .json(#"{"version":"0.34.4"}"#))
        #expect(try await OllamaClient(transport: transport).version() == "0.34.4")
        #expect(transport.requests.first?.method == .get)
    }

    @Test func modelsReadCapabilitiesFromTags() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .json("""
        {"models":[{"name":"a:1","capabilities":["completion","vision","tools","thinking"]},
                   {"name":"b:1","capabilities":["completion","tools"]},
                   {"name":"c:1","capabilities":["embedding"]}]}
        """))
        let models = try await OllamaClient(transport: transport).models()
        #expect(models == [InstalledModel(name: "a:1", readsImages: true, thinks: true),
                           InstalledModel(name: "b:1", readsImages: false, thinks: false),
                           InstalledModel(name: "c:1", readsImages: false, thinks: false)])
        #expect(transport.requests(to: "/api/show").isEmpty)
    }

    @Test func showIsAskedOnlyForEntriesWithoutCapabilities() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .json(#"{"models":[{"name":"old:1"},{"name":"new:1","capabilities":["completion"]}]}"#))
        transport.set("/api/show", .json(#"{"capabilities":["completion","vision"]}"#))
        let models = try await OllamaClient(transport: transport).models()
        #expect(models.first { $0.name == "old:1" }?.readsImages == true)
        #expect(models.first { $0.name == "new:1" }?.readsImages == false)
        let shows = transport.requests(to: "/api/show")
        #expect(shows.count == 1)
        #expect(try body(of: shows[0])["model"] as? String == "old:1")
    }

    @Test func aFailingShowMeansUnknownCapabilitiesNotAFailedList() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/tags", .json(#"{"models":[{"name":"old:1"}]}"#))
        transport.set("/api/show", .status(500))
        let models = try await OllamaClient(transport: transport).models()
        #expect(models == [InstalledModel(name: "old:1", readsImages: false, thinks: false)])
    }

    // MARK: chat request

    @Test func chatSendsTheAgreedBody() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/chat", .json(chatAnswer))
        _ = try await OllamaClient(transport: transport).chat(chatRequest(think: .bool(true), timeout: 123))
        let sent = try #require(transport.requests(to: "/api/chat").first)
        #expect(sent.method == .post)
        #expect(sent.timeout == 123)
        let body = try body(of: sent)
        #expect(body["model"] as? String == "qwen3.8:27b-mlx")
        #expect(body["stream"] as? Bool == false)
        #expect((body["options"] as? [String: Any])?["temperature"] as? Double == 0)
        #expect(body["keep_alive"] == nil)
        #expect(body["think"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Describe it.")
        #expect(messages[0]["images"] as? [String] == [base64])
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["type"] as? String == "object")
        #expect((format["required"] as? [String]) == ["description"])
    }

    @Test func aSystemPromptBecomesTheFirstMessage() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/chat", .json(chatAnswer))
        var request = chatRequest()
        request = ChatRequest(model: request.model, systemPrompt: "Be brief.", prompt: request.prompt, picture: picture,
                              picturePlaceholder: request.picturePlaceholder, schema: testSchema, useNativeFormat: true,
                              think: .bool(false), temperature: 0, timeout: 60)
        _ = try await OllamaClient(transport: transport).chat(request)
        let sent = try #require(transport.requests.first)
        let fields = try body(of: sent)
        let messages = try #require(fields["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test func thinkIsSentAsFalseTrueOrALevelAndOmittedWhenUnsupported() async throws {
        let cases: [(ThinkWireValue, Any?)] = [(.bool(false), false), (.bool(true), true), (.level("high"), "high"), (.omitted, nil)]
        for (wire, expected) in cases {
            let transport = FakeOllamaTransport()
            transport.set("/api/chat", .json(chatAnswer))
            _ = try await OllamaClient(transport: transport).chat(chatRequest(think: wire))
            let sent = try #require(transport.requests.first)
            let think = try body(of: sent)["think"]
            switch expected {
            case let value as Bool: #expect(think as? Bool == value)
            case let value as String: #expect(think as? String == value)
            default: #expect(think == nil)
            }
        }
    }

    @Test func withoutNativeFormatTheSchemaIsInThePromptAndThereIsNoFormat() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/chat", .json(chatAnswer))
        _ = try await OllamaClient(transport: transport).chat(chatRequest(native: false))
        let sent = try #require(transport.requests.first)
        let body = try body(of: sent)
        #expect(body["format"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? String)
        #expect(content.hasPrefix("Describe it."))
        #expect(content.contains("JSON") && content.contains("\"description\""))
    }

    @Test func chatMapsTheAnswerAndItsTimings() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/chat", .json(chatAnswer))
        let answer = try await OllamaClient(transport: transport).chat(chatRequest())
        #expect(answer == ChatResponse(content: #"{"description":"x"}"#, thinking: "hmm", doneReason: "stop",
                                       totalDurationNanoseconds: 4_883_583_458, loadDurationNanoseconds: 1_334_875,
                                       promptEvalNanoseconds: 342_546_000, evalCount: 282))
    }

    @Test func requestJSONHasAPlaceholderAndNeverThePictureData() throws {
        let text = OllamaClient(transport: FakeOllamaTransport()).requestJSON(for: chatRequest())
        #expect(text.contains("[picture abc 2048x857]"))
        #expect(!text.contains(base64))
        #expect(!text.contains(String(base64.prefix(40))))
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["model"] as? String == "qwen3.8:27b-mlx")
    }

    // MARK: failures

    @Test func failuresMapToDistinctErrors() async throws {
        let cases: [(FakeOllamaTransport.Reply, OllamaClientError)] = [
            (.status(500), .serverError(500)), (.status(503), .serverError(503)),
            (.status(400, #"{"error":"bad"}"#), .requestRejected), (.status(404), .requestRejected),
            (.json("not json at all"), .badResponse), (.json(#"{"message":{"role":"assistant"}}"#), .badResponse),
            (.fail(.timedOut), .timedOut), (.fail(.unreachable), .unreachable),
            (.fail(.redirectRefused), .redirectRefused), (.fail(.other("boom")), .badResponse),
        ]
        for (reply, expected) in cases {
            let transport = FakeOllamaTransport()
            transport.set("/api/chat", reply)
            do {
                _ = try await OllamaClient(transport: transport).chat(chatRequest())
                Issue.record("expected \(expected)")
            } catch let error as OllamaClientError {
                #expect(error == expected)
            }
        }
    }

    @Test func thinkWireValueFollowsTheModel() {
        #expect(ThinkWireValue.make(setting: .off, modelThinks: true, acceptsLevels: true) == .bool(false))
        #expect(ThinkWireValue.make(setting: .high, modelThinks: true, acceptsLevels: true) == .level("high"))
        #expect(ThinkWireValue.make(setting: .low, modelThinks: true, acceptsLevels: false) == .bool(true))
        #expect(ThinkWireValue.make(setting: .high, modelThinks: false, acceptsLevels: true) == .omitted)
        #expect(ThinkWireValue.make(setting: .off, modelThinks: false, acceptsLevels: false) == .omitted)
        #expect(ThinkWireValue.acceptsLevels(modelName: "gpt-oss:20b"))
        #expect(!ThinkWireValue.acceptsLevels(modelName: "qwen3.8:27b-mlx"))
    }

    // MARK: embeddings and next-token log probabilities (spec 005)

    @Test func embedPostsTheInputsAndReturnsOneVectorEachInOrder() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/embed", .json(#"{"model":"e5","embeddings":[[0.5,1.5],[2.5,3.5]]}"#))
        let vectors = try await OllamaClient(transport: transport).embed(model: "e5", inputs: ["query: a", "query: b"], timeout: 7)
        #expect(vectors == [[0.5, 1.5], [2.5, 3.5]])
        let sent = try #require(transport.requests(to: "/api/embed").first)
        #expect(sent.method == .post && sent.timeout == 7)
        let body = try body(of: sent)
        #expect(body["model"] as? String == "e5")
        #expect(body["input"] as? [String] == ["query: a", "query: b"])
    }

    @Test func embedRejectsACountMismatchOrAMissingList() async throws {
        for answer in [#"{"embeddings":[[1.0]]}"#, #"{"model":"e5"}"#, #"{"embeddings":"nope"}"#] {
            let transport = FakeOllamaTransport()
            transport.set("/api/embed", .json(answer))
            await #expect(throws: OllamaClientError.badResponse) {
                _ = try await OllamaClient(transport: transport).embed(model: "e5", inputs: ["a", "b"], timeout: 5)
            }
        }
    }

    @Test func nextTokenLogprobsSendsTheRawRequestAndReturnsTheTopTokens() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/generate", .json("""
        {"model":"r","response":"yes","done":true,
         "logprobs":[{"token":"yes","logprob":-0.2,"top_logprobs":[{"token":"yes","logprob":-0.2},{"token":"no","logprob":-1.9}]}]}
        """))
        let top = try await OllamaClient(transport: transport).generateNextTokenLogprobs(model: "r", prompt: "<p>", timeout: 9)
        #expect(top == [TokenLogprob(token: "yes", logprob: -0.2), TokenLogprob(token: "no", logprob: -1.9)])
        let sent = try #require(transport.requests(to: "/api/generate").first)
        #expect(sent.timeout == 9)
        let fields = try body(of: sent)
        #expect(fields["model"] as? String == "r" && fields["prompt"] as? String == "<p>")
        #expect(fields["raw"] as? Bool == true && fields["stream"] as? Bool == false && fields["logprobs"] as? Bool == true)
        #expect(fields["top_logprobs"] as? Int == 5)
        let options = try #require(fields["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 1 && options["temperature"] as? Double == 0)
    }

    @Test func nextTokenLogprobsWithoutLogprobsIsABadResponse() async throws {
        let transport = FakeOllamaTransport()
        transport.set("/api/generate", .json(#"{"model":"r","response":"yes","done":true}"#))
        await #expect(throws: OllamaClientError.badResponse) {
            _ = try await OllamaClient(transport: transport).generateNextTokenLogprobs(model: "r", prompt: "p", timeout: 5)
        }
    }

    @Test func theNewCallsMapFailuresLikeChat() async throws {
        let cases: [(FakeOllamaTransport.Reply, OllamaClientError)] = [
            (.status(500), .serverError(500)), (.status(404), .requestRejected), (.fail(.timedOut), .timedOut), (.fail(.unreachable), .unreachable),
        ]
        for (reply, expected) in cases {
            let transport = FakeOllamaTransport()
            transport.set("/api/embed", reply); transport.set("/api/generate", reply)
            await #expect(throws: expected) { _ = try await OllamaClient(transport: transport).embed(model: "e", inputs: ["a"], timeout: 5) }
            await #expect(throws: expected) { _ = try await OllamaClient(transport: transport).generateNextTokenLogprobs(model: "r", prompt: "p", timeout: 5) }
        }
    }
}
