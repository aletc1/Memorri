import Foundation

/// What a step of analysis can fail with; the queue job maps it to a `JobOutcome` (spec 003).
public enum PipelineError: Error, Sendable, Equatable {
    /// Timeout, lost connection, server error, invalid answer: retried with waits.
    case transient(String)
    /// The request was rejected or the picture is gone: more attempts would not help.
    case permanent(String)
    /// The server or the chosen model went away: no attempt is used.
    case serverUnavailable
}

extension JobOutcome {
    public init(_ error: PipelineError) {
        switch error {
        case .transient(let reason): self = .transient(reason)
        case .permanent(let reason): self = .permanent(reason)
        case .serverUnavailable: self = .serverUnavailable
        }
    }
}

/// The part of the model client a step needs, so tests and `memorri-eval` can replace it.
public protocol ModelChatting: Sendable {
    func chat(_ request: ChatRequest) async throws -> ChatResponse
    /// The request as sent, with the picture replaced by its placeholder (run record).
    func requestJSON(for request: ChatRequest) -> String
}

extension OllamaClient: ModelChatting {}

/// What one attempt reads from the settings: read once at its start, so a change while it runs does not
/// alter it (spec 003, FR-017).
public struct ModelStepSettings: Sendable, Equatable {
    public let model: String
    public let think: ThinkSetting
    public let timeout: TimeInterval
    public let modelThinks: Bool

    public init(model: String, think: ThinkSetting, timeout: TimeInterval, modelThinks: Bool) {
        self.model = model
        self.think = think
        self.timeout = timeout
        self.modelThinks = modelThinks
    }
}

/// What was asked and answered in one model call, for the run record. Never holds picture data.
public struct StepRecord: Sendable, Equatable {
    public let step: String
    public let request: String
    public let rawAnswer: String?
    public let durationMs: Int
    public let failure: String?
    public let model: String
    public let think: String
    public let startedAt: Date
    public let promptVersion: String
    public let schemaVersion: String
}

public struct ModelStepResult: Sendable, Equatable {
    public let value: JSONValue
    public let record: StepRecord
}

public struct ModelStepFailure: Error, Sendable, Equatable {
    public let error: PipelineError
    public let record: StepRecord
}

public enum ModelStep {
    /// The model, think level and timeout from the settings, and whether the chosen model thinks. A model
    /// that is missing or cannot read images means the server is unavailable.
    public static func settings(service: OllamaService, settings: OllamaSettings) async -> Result<ModelStepSettings, PipelineError> {
        guard let model = settings.model else { return .failure(.serverUnavailable) }
        let think = settings.think
        let timeout = TimeInterval(settings.timeoutSeconds)
        let client = await service.client()
        do {
            guard let installed = try await client.models().first(where: { $0.name == model }), installed.readsImages else {
                return .failure(.serverUnavailable)
            }
            return .success(ModelStepSettings(model: model, think: think, timeout: timeout, modelThinks: installed.thinks))
        } catch {
            return .failure(pipelineError(for: error))
        }
    }

    /// One model call with a picture, a required schema and temperature 0, validated against the schema.
    public static func call(using chat: any ModelChatting, settings: ModelStepSettings, step: String, prompt: String,
                            picture: Data, placeholder: String, schema: JSONValue, promptVersion: String,
                            schemaVersion: String, startedAt: Date = Date(), maxTokens: Int? = nil) async -> Result<ModelStepResult, ModelStepFailure> {
        let wire = ThinkWireValue.make(setting: settings.think, modelThinks: settings.modelThinks,
                                       acceptsLevels: ThinkWireValue.acceptsLevels(modelName: settings.model))
        let request = ChatRequest(model: settings.model, systemPrompt: nil, prompt: prompt, picture: picture,
                                  picturePlaceholder: placeholder, schema: schema, useNativeFormat: true,
                                  think: wire, temperature: 0, timeout: settings.timeout, maxTokens: maxTokens)
        let requestJSON = chat.requestJSON(for: request)
        let clock = ContinuousClock()
        let begin = clock.now

        func record(_ raw: String?, failure: String?) -> StepRecord {
            let elapsed = begin.duration(to: clock.now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return StepRecord(step: step, request: requestJSON, rawAnswer: raw, durationMs: ms, failure: failure,
                              model: settings.model, think: label(wire), startedAt: startedAt,
                              promptVersion: promptVersion, schemaVersion: schemaVersion)
        }

        let response: ChatResponse
        do {
            response = try await chat.chat(request)
        } catch {
            let mapped = pipelineError(for: error)
            return .failure(ModelStepFailure(error: mapped, record: record(nil, failure: reason(of: mapped))))
        }

        var answer = response.content
        if let thinking = response.thinking, !thinking.isEmpty { answer += ModelTestJob.thinkingMarker + thinking }
        switch SchemaValidator.validate(response.content, against: schema) {
        case .success(let value):
            return .success(ModelStepResult(value: value, record: record(answer, failure: nil)))
        case .failure:
            return .failure(ModelStepFailure(error: .transient("invalid answer"), record: record(answer, failure: "invalid answer")))
        }
    }

    // MARK: Helpers

    static func pipelineError(for error: Error) -> PipelineError {
        guard let error = error as? OllamaClientError else { return .serverUnavailable }
        switch error {
        case .timedOut: return .transient("timed out")
        case .serverError(let code): return .transient("server error \(code)")
        case .badResponse: return .transient("bad response")
        case .requestRejected: return .permanent("request rejected")
        case .unreachable, .redirectRefused: return .serverUnavailable
        }
    }

    static func reason(of error: PipelineError) -> String {
        switch error {
        case .transient(let text), .permanent(let text): text
        case .serverUnavailable: "server unavailable"
        }
    }

    static func label(_ wire: ThinkWireValue) -> String {
        switch wire {
        case .bool(true): "on"
        case .bool(false), .omitted: "off"
        case .level(let level): level
        }
    }
}

/// The model client for whatever address the settings hold at the moment of the call, so a change of address in
/// Settings reaches the next call without rebuilding the pipeline.
public struct ServiceModelChatting: ModelChatting {
    private let service: OllamaService

    public init(service: OllamaService) { self.service = service }

    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        try await service.client().chat(request)
    }

    public func requestJSON(for request: ChatRequest) -> String { OllamaClient.requestJSON(for: request) }
}
