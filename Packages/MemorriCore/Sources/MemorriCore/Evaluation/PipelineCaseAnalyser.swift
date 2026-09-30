import CoreGraphics
import Foundation
import ImageIO

/// Answers from an earlier run, given back in place of the model so a run can be scored again without calling it.
struct ReplayModel: ModelChatting {
    let answers: [String: String]

    init(steps: [EvalStepRecord]) {
        var answers: [String: String] = [:]
        for step in steps {
            guard let raw = step.rawAnswer else { continue }
            answers[step.step] = raw.components(separatedBy: ModelTestJob.thinkingMarker).first ?? raw
        }
        self.answers = answers
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        var keys: Set<String> = []
        if case .object(let root) = request.schema, case .object(let properties)? = root["properties"] { keys = Set(properties.keys) }
        let step = keys.contains("screen_kind") ? "classify" : "extract"
        guard let answer = answers[step] else { throw OllamaClientError.badResponse }
        return ChatResponse(content: answer, thinking: nil, doneReason: "stop", totalDurationNanoseconds: nil, loadDurationNanoseconds: nil,
                            promptEvalNanoseconds: nil, evalCount: nil)
    }

    func requestJSON(for request: ChatRequest) -> String { OllamaClient.requestJSON(for: request) }
}

public enum PipelineCaseError: Error, Sendable, Equatable {
    case unreadablePicture(String)
}

/// The real `CaseAnalysing`: builds the pipeline's input from a golden case the way the queue job builds it from a stored
/// picture, runs `AnalysisPipeline` and turns the result into what the scores compare (research R14).
public struct PipelineCaseAnalyser: CaseAnalysing {
    private let recogniser: any TextRecogniser
    private let model: any ModelChatting
    private let settings: ModelStepSettings
    private let size: Int
    private let time: any TimeSource
    private let encoder: any ImageEncoding

    public init(recogniser: any TextRecogniser, model: any ModelChatting, settings: ModelStepSettings, size: Int,
                time: any TimeSource = SystemTimeSource(), encoder: any ImageEncoding = HEICImageEncoder()) {
        self.recogniser = recogniser; self.model = model; self.settings = settings; self.size = size; self.time = time; self.encoder = encoder
    }

    public func analyse(_ golden: GoldenCase, replaying steps: [EvalStepRecord]?) async throws -> CaseResult {
        guard let source = CGImageSourceCreateWithURL(golden.pictureURL as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineCaseError.unreadablePicture(golden.name)
        }
        let copy = try encoder.encodeAnalysisCopy(image, longEdge: size)
        let copies = try PictureCopies(analysisCopy: copy.data, width: copy.width, height: copy.height)
        let zone = TimeZone(identifier: golden.meta.macTimezone) ?? .current
        let input = PipelineInput(image: image, classificationJPEG: copies.classificationJPEG, classificationSize: copies.classificationSize,
                                  analysisJPEG: copies.analysisJPEG, analysisSize: copies.analysisSize, macTimezone: zone)

        let chat: any ModelChatting = steps.map { ReplayModel(steps: $0) } ?? model
        let pipeline = AnalysisPipeline(recogniser: recogniser, model: chat, time: time)
        let clock = ContinuousClock()
        let began = clock.now
        do {
            let result = try await pipeline.analyse(input, settings: settings)
            let elapsed = began.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return Self.caseResult(result, seconds: seconds)
        } catch let failure as AnalysisFailure {
            return CaseResult(kind: "failed", findings: [], tags: [], contextName: nil, lines: [], seconds: 0, steps: failure.steps.map(Self.stepRecord))
        }
    }

    static func stepRecord(_ step: StepRecord) -> EvalStepRecord {
        EvalStepRecord(step: step.step, request: step.request, rawAnswer: step.rawAnswer, durationMs: step.durationMs)
    }

    static func caseResult(_ result: AnalysisResult, seconds: Double) -> CaseResult {
        let findings = result.findings.map { f -> FoundFinding in
            let cited = f.citedLines.compactMap { n in result.lines.first { $0.n == n }?.text }.joined(separator: " ")
            return FoundFinding(kind: f.kind.rawValue, title: f.title, start: f.start, end: f.end, due: f.due, remind: f.remind, allDay: f.allDay,
                                people: f.people, place: f.place, inferred: f.provenance.filter { $0.value.origin == .inferred }.keys.sorted(),
                                confidence: f.confidence, citedLines: f.citedLines, citedText: cited)
        }
        return CaseResult(kind: result.classification.kind.rawValue, findings: findings,
                          tags: result.tags.map { FoundTag(key: $0.key, value: $0.value, confidence: $0.confidence) }, contextName: nil,
                          lines: result.lines.map { FoundLine(text: $0.text, box: [$0.box.x, $0.box.y, $0.box.width, $0.box.height]) },
                          seconds: seconds, steps: result.steps.map(stepRecord))
    }
}
