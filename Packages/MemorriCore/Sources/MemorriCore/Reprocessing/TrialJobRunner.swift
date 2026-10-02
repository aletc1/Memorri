import Foundation
import os

/// Runs one `trial` job (spec 008): reads one stored capture with the trial's model, reusing the stored text, and keeps what it found as a
/// proposal. It stops there: it never writes findings, model runs, the analysis row, items or evidence (ADR 0025).
public struct TrialJobRunner: AnalysisJobRunning {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "trial")

    private let service: OllamaService
    private let pipeline: AnalysisPipeline
    private let pictures: any AnalysisPictureProviding
    private let fullPictures: any FullPictureProviding
    private let ocr: OCRStore
    private let store: TrialStore
    private let settings: OllamaSettings
    private let time: any TimeSource
    private let windows: (any WindowProviding)?
    private let contexts: ContextStore?
    private let maxAttempts: Int

    public init(service: OllamaService, pipeline: AnalysisPipeline, pictures: any AnalysisPictureProviding, fullPictures: any FullPictureProviding,
                ocr: OCRStore, store: TrialStore, settings: OllamaSettings, time: any TimeSource, windows: (any WindowProviding)? = nil,
                contexts: ContextStore? = nil, maxAttempts: Int = RetryPolicy.standard.maxAttempts) {
        self.service = service; self.pipeline = pipeline; self.pictures = pictures; self.fullPictures = fullPictures; self.ocr = ocr
        self.store = store; self.settings = settings; self.time = time; self.windows = windows; self.contexts = contexts; self.maxAttempts = maxAttempts
    }

    public func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        guard let trialID = job.trialId, let imageID = job.imageId else { return .permanent("not a trial job") }
        // A cancelled or deleted trial, or a capture already read, has nothing left to do.
        guard let trial = try? store.trial(id: trialID), trial.state == .running,
              (try? store.state(trialID: trialID, imageID: imageID)) == .waiting else { return .success }

        guard let analysisCopy = try? pictures.analysisPicture(imageID: imageID), let full = try? fullPictures.fullPicture(imageID: imageID),
              let copies = try? PictureCopies(analysisCopy: analysisCopy.data, width: analysisCopy.width, height: analysisCopy.height) else {
            try? store.mark(trialID: trialID, imageID: imageID, .skipped, reason: "picture no longer stored", at: time.now())
            return .success
        }
        let stepSettings: ModelStepSettings
        switch await ModelStep.settings(service: service, model: trial.model, think: ThinkSetting(rawValue: trial.think) ?? settings.think,
                                        timeout: TimeInterval(settings.timeoutSeconds)) {
        case .success(let value): stepSettings = value
        case .failure(let error):
            // The queue holds every job when the server is down, and a trial job sent back as unavailable would stall the captures behind it
            // for a recheck interval, again and again. When the server is up, the trial's model is the one that is missing.
            if error == .serverUnavailable, (await service.check()).isUsable {
                return fail(trialID, imageID, attempt, .permanent("\(trial.model) is not installed or cannot read pictures"))
            }
            return JobOutcome(error)
        }

        let lines: [RecognisedLine]
        if (try? ocr.isRead(imageID: imageID)) == true, let stored = try? ocr.lines(imageID: imageID) { lines = stored }
        else if let read = try? await pipeline.read(full) { lines = read }          // not stored: a trial leaves the library as it is
        else { return fail(trialID, imageID, attempt, .transient("text recognition failed")) }

        // The same context inputs as live analysis: the user's contexts and what the user chose for this picture decide the time zone dates are read in.
        let knownContexts = (try? contexts?.all()) ?? []
        let choice = (try? contexts?.decision(imageID: imageID)).flatMap { $0 }.flatMap { $0.source == .user ? $0 : nil }
        let input = PipelineInput(image: full, classificationJPEG: copies.classificationJPEG, classificationSize: copies.classificationSize,
                                  analysisJPEG: copies.analysisJPEG, analysisSize: copies.analysisSize, macTimezone: .current,
                                  captureTime: analysisCopy.capturedAt ?? time.now(), reuse: PipelineInput.Reuse(lines: lines), contexts: knownContexts,
                                  windows: (try? windows?.windows(imageID: imageID)) ?? [], userChoice: choice, displayScale: analysisCopy.scale)
        let started = ContinuousClock.now
        do {
            let result = try await pipeline.analyse(input, settings: stepSettings)
            let elapsed = started.duration(to: .now).components
            let ms = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            try store.saveProposal(trialID: trialID, imageID: imageID, result: result, durationMs: ms, at: time.now())
            Self.logger.info("trial read image=\(imageID, privacy: .public) findings=\(result.findings.count) ms=\(ms)")
            return .success
        } catch let failure as AnalysisFailure {
            if failure.error == .serverUnavailable { return .serverUnavailable }
            return fail(trialID, imageID, attempt, JobOutcome(failure.error))
        } catch {
            return fail(trialID, imageID, attempt, .transient("could not store the proposal"))
        }
    }

    /// A permanent failure, or the last attempt, marks the capture failed in the trial so the trial can finish; it can be retried.
    private func fail(_ trialID: String, _ imageID: String, _ attempt: Int, _ outcome: JobOutcome) -> JobOutcome {
        var reason: String?
        switch outcome {
        case .permanent(let why): reason = why
        case .transient(let why): if attempt >= maxAttempts { reason = why }
        default: break
        }
        if let reason {
            try? store.mark(trialID: trialID, imageID: imageID, .failed, reason: reason, at: time.now())
            Self.logger.error("trial failed image=\(imageID, privacy: .public) reason=\(reason, privacy: .public)")
        }
        return outcome
    }
}
