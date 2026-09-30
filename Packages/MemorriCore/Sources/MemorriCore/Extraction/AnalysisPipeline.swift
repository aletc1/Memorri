import CoreGraphics
import Foundation

/// What `AnalysisPipeline.analyse` needs for one picture.
public struct PipelineInput: @unchecked Sendable {
    /// What an earlier attempt of the same job already produced.
    public struct Reuse: Sendable {
        public var lines: [RecognisedLine]?
        public var classification: ClassificationResult?
        public init(lines: [RecognisedLine]? = nil, classification: ClassificationResult? = nil) {
            self.lines = lines; self.classification = classification
        }
    }

    /// The full-resolution picture, for reading.
    public let image: CGImage
    /// The picture at about 1024 pixels as JPEG, for the classification call (spike S2).
    public let classificationJPEG: Data
    public let classificationSize: (width: Int, height: Int)
    public let reuse: Reuse

    public init(image: CGImage, classificationJPEG: Data, classificationSize: (width: Int, height: Int), reuse: Reuse = Reuse()) {
        self.image = image; self.classificationJPEG = classificationJPEG; self.classificationSize = classificationSize; self.reuse = reuse
    }
}

/// What one analysis found, step by step (ADR 0014).
public struct AnalysisResult: Sendable {
    public let lines: [RecognisedLine]
    /// Already resolved: an unsure answer is `other`.
    public let classification: ClassificationResult
    /// The model calls made in this run (none for a step that was reused), in order.
    public let steps: [StepRecord]
}

/// An analysis that stopped. The steps made so far are kept so the caller can still record the failed call.
public struct AnalysisFailure: Error, Sendable, Equatable {
    public let error: PipelineError
    public let steps: [StepRecord]
}

/// The one way a picture is analysed: the queue job and `memorri-eval` both call it (ADR 0014).
public struct AnalysisPipeline: Sendable {
    private let recogniser: any TextRecogniser
    private let model: any ModelChatting
    private let time: any TimeSource

    public init(recogniser: any TextRecogniser, model: any ModelChatting, time: any TimeSource) {
        self.recogniser = recogniser
        self.model = model
        self.time = time
    }

    /// The read step on its own, so the job can store the lines before any model call.
    public func read(_ image: CGImage) async throws -> [RecognisedLine] {
        do { return try await recogniser.recognise(image) }
        catch { throw AnalysisFailure(error: .transient("text recognition failed"), steps: []) }
    }

    public func analyse(_ input: PipelineInput, settings: ModelStepSettings) async throws -> AnalysisResult {
        var steps: [StepRecord] = []

        let lines: [RecognisedLine]
        if let reused = input.reuse.lines {
            lines = reused
        } else {
            do { lines = try await recogniser.recognise(input.image) }
            catch { throw AnalysisFailure(error: .transient("text recognition failed"), steps: steps) }
        }

        let classification: ClassificationResult
        if let reused = input.reuse.classification {
            classification = reused
        } else {
            let placeholder = "[picture \(input.classificationSize.width)x\(input.classificationSize.height)]"
            let result = await ModelStep.call(using: model, settings: settings, step: "classify", prompt: ExtractionPrompts.classifyPrompt(),
                                              picture: input.classificationJPEG, placeholder: placeholder,
                                              schema: ExtractionSchemas.classifySchema, promptVersion: ExtractionPrompts.classifyVersion,
                                              schemaVersion: "schema-classify-v1", startedAt: time.now())
            switch result {
            case .failure(let failure):
                steps.append(failure.record)
                throw AnalysisFailure(error: failure.error, steps: steps)
            case .success(let value):
                steps.append(value.record)
                guard let parsed = ClassificationResult.parse(value.value) else {
                    throw AnalysisFailure(error: .transient("invalid answer"), steps: steps)
                }
                classification = parsed
            }
        }
        return AnalysisResult(lines: lines, classification: classification.resolved(), steps: steps)
    }
}
