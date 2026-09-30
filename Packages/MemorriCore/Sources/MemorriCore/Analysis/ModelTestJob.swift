import CoreGraphics
import Foundation
import os

/// What one attempt of a job came to (ADR 0012).
public enum JobOutcome: Sendable, Equatable {
    case success
    /// Timeout, lost connection, server error or an answer that does not match the schema.
    case transient(String)
    /// Picture no longer stored, or the request was rejected: more attempts would not help.
    case permanent(String)
    /// The server or the chosen model went away mid-job: no attempt is used.
    case serverUnavailable
}

public protocol AnalysisJobRunning: Sendable {
    /// Runs one attempt (`attempt` is 1 or more) and records its model run.
    func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome
}

/// The only job in this spec: ask the model to describe a picture. Spec 004 adds real prompts.
public enum ModelTestJob {
    public static let promptVersion = "test-v1"
    public static let schemaVersion = "test-v1"
    public static let prompt = "Describe this picture in one or two sentences. Say whether it contains readable text, and copy a short sample of any text you can read."
    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "description": .object(["type": .string("string")]),
            "contains_text": .object(["type": .string("boolean")]),
            "text_sample": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("description"), .string("contains_text"), .string("text_sample")]),
        "additionalProperties": .bool(false),
    ])
    /// Longer side of the built-in picture; the spike's default size.
    static let sampleLongEdge = 2048
}

/// Runs one attempt of the test job: reads the settings, converts the picture, asks the model,
/// validates the answer and records the run. The settings are read at the start of every attempt.
public struct ModelTestJobRunner: AnalysisJobRunning {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "ollama")

    private let service: OllamaService
    private let store: any AnalysisJobStoring
    private let pictures: any AnalysisPictureProviding
    private let settings: OllamaSettings
    private let time: any TimeSource

    public init(service: OllamaService, store: any AnalysisJobStoring, pictures: any AnalysisPictureProviding,
                settings: OllamaSettings, time: any TimeSource) {
        self.service = service
        self.store = store
        self.pictures = pictures
        self.settings = settings
        self.time = time
    }

    public func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        guard let model = settings.model else { return .serverUnavailable }
        let think = settings.think
        let timeout = TimeInterval(settings.timeoutSeconds)

        guard let picture = loadPicture(for: job) else { return .permanent("picture no longer stored") }
        let jpeg: Data
        do { jpeg = try picture.jpeg() } catch { return .permanent("picture no longer stored") }

        let client = await service.client()
        let modelThinks: Bool
        do {
            guard let installed = try await client.models().first(where: { $0.name == model }), installed.readsImages else {
                return .serverUnavailable
            }
            modelThinks = installed.thinks
        } catch {
            return Self.outcome(for: error) ?? .serverUnavailable
        }

        let wire = ThinkWireValue.make(setting: think, modelThinks: modelThinks,
                                       acceptsLevels: ThinkWireValue.acceptsLevels(modelName: model))
        let request = ChatRequest(model: model, systemPrompt: nil, prompt: ModelTestJob.prompt, picture: jpeg,
                                  picturePlaceholder: picture.placeholder, schema: ModelTestJob.schema,
                                  useNativeFormat: true, think: wire, temperature: 0, timeout: timeout)
        let startedAt = time.now()
        let clock = ContinuousClock()
        let begin = clock.now

        func record(_ failureReason: String?, answer: String?) -> JobOutcome? {
            let elapsed = begin.duration(to: clock.now)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let run = ModelRunRecord(jobId: job.id, imageId: job.imageId, attempt: attempt, model: model,
                                     think: Self.label(wire), temperature: 0, imageLongEdge: picture.longEdge,
                                     promptVersion: ModelTestJob.promptVersion, schemaVersion: ModelTestJob.schemaVersion,
                                     startedAt: startedAt, durationMs: milliseconds,
                                     outcome: failureReason == nil ? .success : .failed, failureReason: failureReason,
                                     requestJson: client.requestJSON(for: request), rawAnswer: answer)
            Self.logger.info("request model=\(model, privacy: .public) think=\(run.think, privacy: .public) size=\(picture.longEdge) attempt=\(attempt) ms=\(milliseconds) outcome=\(run.outcome, privacy: .public) reason=\(failureReason ?? "-", privacy: .public)")
            do { try store.record(run: run) } catch {
                // The capture was deleted while the request ran: its runs go with it.
                return job.imageId != nil ? .permanent("picture no longer stored") : .permanent("could not record the run")
            }
            return nil
        }

        let response: ChatResponse
        do {
            response = try await client.chat(request)
        } catch {
            guard let outcome = Self.outcome(for: error) else { return .serverUnavailable }
            if case .serverUnavailable = outcome { return outcome }
            let reason: String
            switch outcome {
            case .transient(let text), .permanent(let text): reason = text
            default: reason = "failed"
            }
            return record(reason, answer: nil) ?? outcome
        }

        var answer = response.content
        if let thinking = response.thinking, !thinking.isEmpty { answer += "\n\n[thinking]\n" + thinking }
        switch SchemaValidator.validate(response.content, against: ModelTestJob.schema) {
        case .success:
            return record(nil, answer: answer) ?? .success
        case .failure:
            return record("invalid answer", answer: answer) ?? .transient("invalid answer")
        }
    }

    // MARK: Helpers

    private struct Prepared {
        let data: Data?
        let image: CGImage?
        let longEdge: Int
        let placeholder: String

        func jpeg() throws -> Data {
            if let image { return try PictureConverter.jpegData(from: image) }
            return try PictureConverter.jpegData(from: data ?? Data())
        }
    }

    private func loadPicture(for job: AnalysisJobRecord) -> Prepared? {
        guard let imageID = job.imageId else {
            let edge = ModelTestJob.sampleLongEdge
            return Prepared(data: nil, image: SamplePicture.make(longEdge: edge), longEdge: edge,
                            placeholder: "[picture sample \(edge)x\(edge * 9 / 16)]")
        }
        guard let stored = try? pictures.analysisPicture(imageID: imageID) else { return nil }
        return Prepared(data: stored.data, image: nil, longEdge: stored.longEdge,
                        placeholder: "[picture \(imageID) \(stored.width)x\(stored.height)]")
    }

    /// nil: not an error this runner knows (treated as the server being unavailable by the caller).
    private static func outcome(for error: Error) -> JobOutcome? {
        guard let error = error as? OllamaClientError else { return nil }
        switch error {
        case .timedOut: return .transient("timed out")
        case .serverError(let code): return .transient("server error \(code)")
        case .badResponse: return .transient("bad response")
        case .requestRejected: return .permanent("request rejected")
        case .unreachable, .redirectRefused: return .serverUnavailable
        }
    }

    private static func label(_ wire: ThinkWireValue) -> String {
        switch wire {
        case .bool(true): "on"
        case .bool(false), .omitted: "off"
        case .level(let level): level
        }
    }
}
