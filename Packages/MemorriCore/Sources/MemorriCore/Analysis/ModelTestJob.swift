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
    /// Separates the answer from the thinking text in a run's `raw_answer`.
    public static let thinkingMarker = "\n\n[thinking]\n"
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
        guard settings.model != nil else { return .serverUnavailable }

        guard let picture = loadPicture(for: job) else { return .permanent("picture no longer stored") }
        let jpeg: Data
        do { jpeg = try picture.jpeg() } catch { return .permanent("picture no longer stored") }

        let stepSettings: ModelStepSettings
        switch await ModelStep.settings(service: service, settings: settings) {
        case .success(let value): stepSettings = value
        case .failure(let error): return JobOutcome(error)
        }

        let result = await ModelStep.call(using: await service.client(), settings: stepSettings, step: "test",
                                          prompt: ModelTestJob.prompt, picture: jpeg, placeholder: picture.placeholder,
                                          schema: ModelTestJob.schema, promptVersion: ModelTestJob.promptVersion,
                                          schemaVersion: ModelTestJob.schemaVersion, startedAt: time.now())
        let step: StepRecord, outcome: JobOutcome
        switch result {
        case .success(let value):
            step = value.record; outcome = .success
        case .failure(let failure):
            if failure.error == .serverUnavailable { return .serverUnavailable }   // no attempt, no run
            step = failure.record; outcome = JobOutcome(failure.error)
        }

        let run = ModelRunRecord(jobId: job.id, imageId: job.imageId, attempt: attempt, model: step.model, think: step.think,
                                 temperature: 0, imageLongEdge: picture.longEdge, promptVersion: step.promptVersion,
                                 schemaVersion: step.schemaVersion, startedAt: step.startedAt, durationMs: step.durationMs,
                                 outcome: step.failure == nil ? .success : .failed, failureReason: step.failure,
                                 requestJson: step.request, rawAnswer: step.rawAnswer, step: step.step)
        Self.logger.info("request model=\(run.model, privacy: .public) think=\(run.think, privacy: .public) size=\(picture.longEdge) attempt=\(attempt) ms=\(run.durationMs) outcome=\(run.outcome, privacy: .public) reason=\(step.failure ?? "-", privacy: .public)")
        do { try store.record(run: run) } catch {
            // The capture was deleted while the request ran: its runs go with it.
            return job.imageId != nil ? .permanent("picture no longer stored") : .permanent("could not record the run")
        }
        return outcome
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

}
