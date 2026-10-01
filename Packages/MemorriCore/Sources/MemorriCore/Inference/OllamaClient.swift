import Foundation

public struct InstalledModel: Sendable, Equatable {
    public let name: String
    /// `capabilities` contains `vision`.
    public let readsImages: Bool
    /// `capabilities` contains `thinking`.
    public let thinks: Bool

    public init(name: String, readsImages: Bool, thinks: Bool) {
        self.name = name
        self.readsImages = readsImages
        self.thinks = thinks
    }
}

public enum OllamaClientError: Error, Sendable, Equatable {
    case serverError(Int)
    /// The server refused the request itself (HTTP 4xx).
    case requestRejected
    case badResponse
    case timedOut
    case unreachable
    case redirectRefused
}

/// What goes into the `think` field: a boolean, a level, or nothing for a model that cannot think.
public enum ThinkWireValue: Sendable, Equatable {
    case bool(Bool)
    case level(String)
    case omitted

    /// `off` gives false; a level gives the level when the model accepts levels, else true (on); a
    /// model that does not think gets no field at all.
    public static func make(setting: ThinkSetting, modelThinks: Bool, acceptsLevels: Bool) -> ThinkWireValue {
        guard modelThinks else { return .omitted }
        if setting == .off { return .bool(false) }
        return acceptsLevels ? .level(setting.rawValue) : .bool(true)
    }

    /// Spike S2 (2026-09-30): `qwen3.8` takes level strings but treats them like `true`, so it counts
    /// as boolean only. The documented level models are the GPT-OSS family.
    public static func acceptsLevels(modelName: String) -> Bool {
        modelName.lowercased().hasPrefix("gpt-oss")
    }
}

public struct ChatRequest: Sendable {
    public let model: String
    public let systemPrompt: String?
    public let prompt: String
    /// JPEG or PNG bytes (the server does not read HEIC, spike S2); sent as base64, never stored.
    public let picture: Data
    /// What the run record shows instead of the picture, such as `[picture <id> 2048x857]`.
    public let picturePlaceholder: String
    public let schema: JSONValue
    /// true: the schema goes in `format`. false: it is described in the prompt and there is no `format`.
    public let useNativeFormat: Bool
    public let think: ThinkWireValue
    public let temperature: Double
    public let timeout: TimeInterval
    /// A limit on the answer's length (`num_predict`). A model that falls into a loop ends at it instead of at the timeout.
    public let maxTokens: Int?

    public init(model: String, systemPrompt: String?, prompt: String, picture: Data, picturePlaceholder: String,
                schema: JSONValue, useNativeFormat: Bool, think: ThinkWireValue, temperature: Double,
                timeout: TimeInterval, maxTokens: Int? = nil) {
        self.maxTokens = maxTokens
        self.model = model
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.picture = picture
        self.picturePlaceholder = picturePlaceholder
        self.schema = schema
        self.useNativeFormat = useNativeFormat
        self.think = think
        self.temperature = temperature
        self.timeout = timeout
    }
}

public struct ChatResponse: Sendable, Equatable {
    public let content: String
    public let thinking: String?
    public let doneReason: String?
    public let totalDurationNanoseconds: Int64?
    public let loadDurationNanoseconds: Int64?
    public let promptEvalNanoseconds: Int64?
    public let evalCount: Int?

    public init(content: String, thinking: String?, doneReason: String?, totalDurationNanoseconds: Int64?,
                loadDurationNanoseconds: Int64?, promptEvalNanoseconds: Int64?, evalCount: Int?) {
        self.content = content
        self.thinking = thinking
        self.doneReason = doneReason
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.loadDurationNanoseconds = loadDurationNanoseconds
        self.promptEvalNanoseconds = promptEvalNanoseconds
        self.evalCount = evalCount
    }
}

/// A candidate first token and its natural log probability.
public struct TokenLogprob: Sendable, Equatable {
    public let token: String
    public let logprob: Double

    public init(token: String, logprob: Double) { self.token = token; self.logprob = logprob }
}

/// Plain requests and answers for the four calls the app uses. No policy: retries, waiting and
/// status belong to the service and the queue.
public struct OllamaClient: Sendable {
    /// Limit for the small calls (the health check has the same limit overall).
    public static let quickTimeout: TimeInterval = 5

    private let transport: any OllamaTransport

    public init(transport: any OllamaTransport) {
        self.transport = transport
    }

    public func version() async throws -> String {
        let object = try await object(for: OllamaHTTPRequest(method: .get, path: "/api/version", timeout: Self.quickTimeout))
        guard case .string(let version)? = object["version"] else { throw OllamaClientError.badResponse }
        return version
    }

    /// The installed models. Capabilities come from `/api/tags`; a model whose entry has none is
    /// looked up with `/api/show`, and stays "unknown" (cannot read images) if that fails too.
    public func models() async throws -> [InstalledModel] {
        let tags = try await object(for: OllamaHTTPRequest(method: .get, path: "/api/tags", timeout: Self.quickTimeout))
        guard case .array(let entries)? = tags["models"] else { throw OllamaClientError.badResponse }
        var models: [InstalledModel] = []
        for entry in entries {
            guard case .object(let fields) = entry, case .string(let name)? = fields["name"] else { continue }
            var capabilities = Self.capabilities(in: fields)
            if capabilities == nil { capabilities = await showCapabilities(of: name) }
            models.append(InstalledModel(name: name, readsImages: capabilities?.contains("vision") ?? false,
                                         thinks: capabilities?.contains("thinking") ?? false))
        }
        return models
    }

    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        let body = try Self.encode(Self.body(for: request, picture: .string(request.picture.base64EncodedString())))
        let fields = try await object(for: OllamaHTTPRequest(method: .post, path: "/api/chat", body: body, timeout: request.timeout))
        guard case .object(let message)? = fields["message"], case .string(let content)? = message["content"] else {
            throw OllamaClientError.badResponse
        }
        return ChatResponse(
            content: content,
            thinking: Self.string(message["thinking"]),
            doneReason: Self.string(fields["done_reason"]),
            totalDurationNanoseconds: Self.int64(fields["total_duration"]),
            loadDurationNanoseconds: Self.int64(fields["load_duration"]),
            promptEvalNanoseconds: Self.int64(fields["prompt_eval_duration"]),
            evalCount: Self.int64(fields["eval_count"]).map(Int.init))
    }

    /// One vector per input, in order (`/api/embed`).
    public func embed(model: String, inputs: [String], timeout: TimeInterval) async throws -> [[Float]] {
        let body = try Self.encode(.object(["model": .string(model), "input": .array(inputs.map(JSONValue.string))]))
        let fields = try await object(for: OllamaHTTPRequest(method: .post, path: "/api/embed", body: body, timeout: timeout))
        guard case .array(let rows)? = fields["embeddings"], rows.count == inputs.count else { throw OllamaClientError.badResponse }
        return try rows.map { row in
            guard case .array(let numbers) = row else { throw OllamaClientError.badResponse }
            return try numbers.map { number in
                switch number {
                case .double(let value): Float(value)
                case .int(let value): Float(value)
                default: throw OllamaClientError.badResponse
                }
            }
        }
    }

    /// The most likely first tokens of the answer to a raw prompt, with their log probabilities (`/api/generate` with
    /// `raw`, one token, `logprobs`). Used for yes/no judgments.
    public func generateNextTokenLogprobs(model: String, prompt: String, timeout: TimeInterval) async throws -> [TokenLogprob] {
        let body = try Self.encode(.object([
            "model": .string(model), "prompt": .string(prompt), "raw": .bool(true), "stream": .bool(false),
            "logprobs": .bool(true), "top_logprobs": .int(5),
            "options": .object(["temperature": .double(0), "num_predict": .int(1)]),
        ]))
        let fields = try await object(for: OllamaHTTPRequest(method: .post, path: "/api/generate", body: body, timeout: timeout))
        guard case .array(let steps)? = fields["logprobs"], case .object(let first)? = steps.first,
              case .array(let top)? = first["top_logprobs"] else { throw OllamaClientError.badResponse }
        let tokens: [TokenLogprob] = top.compactMap { entry in
            guard case .object(let item) = entry, let token = Self.string(item["token"]) else { return nil }
            switch item["logprob"] {
            case .double(let value)?: return TokenLogprob(token: token, logprob: value)
            case .int(let value)?: return TokenLogprob(token: token, logprob: Double(value))
            default: return nil
            }
        }
        guard !tokens.isEmpty else { throw OllamaClientError.badResponse }
        return tokens
    }

    /// The request exactly as sent, with the picture replaced by its placeholder (run record).
    public func requestJSON(for request: ChatRequest) -> String { Self.requestJSON(for: request) }

    public static func requestJSON(for request: ChatRequest) -> String {
        let data = (try? encode(body(for: request, picture: .string(request.picturePlaceholder)))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Building and reading

    private static func body(for request: ChatRequest, picture: JSONValue) -> JSONValue {
        var prompt = request.prompt
        if !request.useNativeFormat {
            let schemaText = (try? encode(request.schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            prompt += "\n\nAnswer with JSON only, matching exactly this JSON schema:\n\(schemaText)"
        }
        var messages: [JSONValue] = []
        if let system = request.systemPrompt {
            messages.append(.object(["role": .string("system"), "content": .string(system)]))
        }
        messages.append(.object(["role": .string("user"), "content": .string(prompt), "images": .array([picture])]))
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .bool(false),
            "messages": .array(messages),
            "options": .object(request.maxTokens.map { ["temperature": .double(request.temperature), "num_predict": .int($0)] }
                               ?? ["temperature": .double(request.temperature)]),
        ]
        if request.useNativeFormat { body["format"] = request.schema }
        switch request.think {
        case .bool(let value): body["think"] = .bool(value)
        case .level(let level): body["think"] = .string(level)
        case .omitted: break
        }
        return .object(body)
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func object(for request: OllamaHTTPRequest) async throws -> [String: JSONValue] {
        let response = try await send(request)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              case .object(let fields) = value else { throw OllamaClientError.badResponse }
        return fields
    }

    private func send(_ request: OllamaHTTPRequest) async throws -> OllamaHTTPResponse {
        let response: OllamaHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as OllamaTransportError {
            switch error {
            case .unreachable: throw OllamaClientError.unreachable
            case .timedOut: throw OllamaClientError.timedOut
            case .redirectRefused: throw OllamaClientError.redirectRefused
            case .other: throw OllamaClientError.badResponse
            }
        }
        switch response.status {
        case 200..<300: return response
        case 400..<500: throw OllamaClientError.requestRejected
        default: throw OllamaClientError.serverError(response.status)
        }
    }

    private func showCapabilities(of name: String) async -> [String]? {
        let body = try? Self.encode(.object(["model": .string(name)]))
        guard let fields = try? await object(for: OllamaHTTPRequest(method: .post, path: "/api/show", body: body,
                                                                   timeout: Self.quickTimeout)) else { return nil }
        return Self.capabilities(in: fields)
    }

    private static func capabilities(in fields: [String: JSONValue]) -> [String]? {
        guard case .array(let items)? = fields["capabilities"] else { return nil }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { text } else { nil }
    }

    private static func int64(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let number)?: Int64(number)
        case .double(let number)?: Int64(number)
        default: nil
        }
    }
}
