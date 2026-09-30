import CoreGraphics
import Foundation
import os

/// Runs one attempt of an `analyse` or `analyse-force` job (ADR 0014): read, classify, and the steps later stories add.
/// Every step keeps its result (lines in `ocr_*`, each model call as a `model_runs` row), so a repeated attempt skips
/// the steps that are already done and a forced job redoes them all.
public struct ImageAnalysisJobRunner: AnalysisJobRunning {
    public static let analyseKind = "analyse"
    public static let forceKind = "analyse-force"
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "extraction")

    private let service: OllamaService
    private let pipeline: AnalysisPipeline
    private let pictures: any AnalysisPictureProviding
    private let fullPictures: any FullPictureProviding
    private let ocr: OCRStore
    private let results: AnalysisResultStore
    private let jobs: any AnalysisJobStoring
    private let settings: OllamaSettings
    private let time: any TimeSource
    private let recogniserName: String
    private let contexts: ContextStore?
    private let windows: (any WindowProviding)?

    public init(service: OllamaService, pipeline: AnalysisPipeline, pictures: any AnalysisPictureProviding,
                fullPictures: any FullPictureProviding, ocr: OCRStore, results: AnalysisResultStore, jobs: any AnalysisJobStoring,
                settings: OllamaSettings, time: any TimeSource, recogniserName: String = VisionTextRecogniser.descriptor,
                contexts: ContextStore? = nil, windows: (any WindowProviding)? = nil) {
        self.service = service
        self.pipeline = pipeline
        self.pictures = pictures
        self.fullPictures = fullPictures
        self.ocr = ocr
        self.results = results
        self.jobs = jobs
        self.settings = settings
        self.time = time
        self.recogniserName = recogniserName
        self.contexts = contexts
        self.windows = windows
    }

    private static let gone = JobOutcome.permanent("picture no longer stored")

    public func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        guard let imageID = job.imageId, let analysisCopy = try? pictures.analysisPicture(imageID: imageID),
              let full = try? fullPictures.fullPicture(imageID: imageID) else { return Self.gone }
        let forced = job.kind == Self.forceKind

        let stepSettings: ModelStepSettings
        switch await ModelStep.settings(service: service, settings: settings) {
        case .success(let value): stepSettings = value
        case .failure(let error): return JobOutcome(error)
        }

        // Read
        let lines: [RecognisedLine]
        do { lines = try await readStep(imageID: imageID, image: full, forced: forced) }
        catch let failure as AnalysisFailure { return JobOutcome(failure.error) }
        catch { return .transient("text recognition failed") }

        // Classify and extract
        let copies: PictureCopies
        do { copies = try PictureCopies(analysisCopy: analysisCopy.data, width: analysisCopy.width, height: analysisCopy.height) }
        catch { return Self.gone }
        let size = copies.classificationSize

        var reuse = PipelineInput.Reuse(lines: lines)
        if !forced, let run = try? jobs.latestSuccessfulRun(imageID: imageID, step: "classify", promptVersion: ExtractionPrompts.classifyVersion),
           let stored = run.rawAnswer.flatMap({ ClassificationResult.parse(storedAnswer: $0) }) {
            reuse.classification = stored
        }
        // The context step's inputs: the user's contexts, the windows seen with the picture and what the user chose for it.
        let knownContexts = (try? contexts?.all()) ?? []
        let choice = (try? contexts?.decision(imageID: imageID)).flatMap { $0 }.flatMap { $0.source == .user ? $0 : nil }
        let input = PipelineInput(image: full, classificationJPEG: copies.classificationJPEG, classificationSize: size,
                                  analysisJPEG: copies.analysisJPEG, analysisSize: copies.analysisSize, macTimezone: .current,
                                  captureTime: analysisCopy.capturedAt ?? time.now(), reuse: reuse, contexts: knownContexts,
                                  windows: (try? windows?.windows(imageID: imageID)) ?? [], userChoice: choice, displayScale: analysisCopy.scale)

        let analysis: AnalysisResult?
        let steps: [StepRecord]
        let outcome: JobOutcome
        do {
            let result = try await pipeline.analyse(input, settings: stepSettings)
            analysis = result
            steps = result.steps
            outcome = .success
        } catch let failure as AnalysisFailure {
            if failure.error == .serverUnavailable { return .serverUnavailable }   // no attempt, no run
            analysis = nil
            steps = failure.steps
            outcome = JobOutcome(failure.error)
        } catch {
            return .transient("analysis failed")
        }

        var runIDs: [String: String] = [:]
        for step in steps {
            let edge = step.step == "classify" ? max(size.width, size.height) : analysisCopy.longEdge
            let run = ModelRunRecord(jobId: job.id, imageId: imageID, attempt: attempt, model: step.model, think: step.think, temperature: 0,
                                     imageLongEdge: edge, promptVersion: step.promptVersion,
                                     schemaVersion: step.schemaVersion, startedAt: step.startedAt, durationMs: step.durationMs,
                                     outcome: step.failure == nil ? .success : .failed, failureReason: step.failure,
                                     requestJson: step.request, rawAnswer: step.rawAnswer, step: step.step)
            // The capture may have been deleted while the request ran: its runs go with it.
            do { try jobs.record(run: run) } catch { return Self.gone }
            runIDs[step.step] = run.id
        }
        guard let analysis else { return outcome }

        if let classify = steps.first(where: { $0.step == "classify" }) {
            Self.logger.info("classify image=\(imageID, privacy: .public) kind=\(analysis.classification.kind.rawValue, privacy: .public) confidence=\(analysis.classification.confidence) ms=\(classify.durationMs)")
        }
        if let extract = steps.first(where: { $0.step == "extract" }) {
            Self.logger.info("extract image=\(imageID, privacy: .public) kind=\(analysis.classification.kind.rawValue, privacy: .public) findings=\(analysis.findings.count) discarded=\(analysis.discards.count) ms=\(extract.durationMs)")
        }
        let contextName = knownContexts.first { $0.id == analysis.decision.contextID }?.name
        Self.logger.info("context image=\(imageID, privacy: .public) source=\(analysis.decision.source.rawValue, privacy: .public) name=\(contextName ?? "-", privacy: .public)")
        let unresolved = analysis.findings.reduce(0) { $0 + $1.unresolved.count }
        let inferred = analysis.findings.reduce(0) { $0 + $1.provenance.values.filter { $0.origin == .inferred }.count }
        Self.logger.info("resolve image=\(imageID, privacy: .public) unresolved=\(unresolved) inferred=\(inferred)")
        do { try results.save(analysis, imageID: imageID, runID: runIDs["extract"], at: time.now()) }
        catch { return .transient("could not store the analysis") }
        Self.logger.info("analysis stored image=\(imageID, privacy: .public)")
        return .success
    }

    private func readStep(imageID: String, image: CGImage, forced: Bool) async throws -> [RecognisedLine] {
        if !forced, (try? ocr.isRead(imageID: imageID)) == true, let stored = try? ocr.lines(imageID: imageID) { return stored }
        let started = time.now()
        let lines = try await pipeline.read(image)
        let ms = max(0, Int((time.now().timeIntervalSince(started) * 1000).rounded()))
        do { try ocr.save(imageID: imageID, lines: lines, durationMs: ms, recogniser: recogniserName, at: time.now()) }
        catch { throw AnalysisFailure(error: .transient("text recognition failed"), steps: []) }
        Self.logger.info("read image=\(imageID, privacy: .public) lines=\(lines.count) ms=\(ms)")
        return lines
    }
}
