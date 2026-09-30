import CoreGraphics
import Foundation
import os

/// Runs one attempt of an `analyse` or `analyse-force` job (ADR 0014): read, then the steps that later stories add.
/// Every step stores its result in one transaction, so a repeated attempt skips the steps that are already done, and
/// a forced job redoes them all.
public struct ImageAnalysisJobRunner: AnalysisJobRunning {
    public static let analyseKind = "analyse"
    public static let forceKind = "analyse-force"
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "extraction")

    private let pictures: any FullPictureProviding
    private let recogniser: any TextRecogniser
    private let ocr: OCRStore
    private let time: any TimeSource
    private let recogniserName: String

    public init(pictures: any FullPictureProviding, recogniser: any TextRecogniser, ocr: OCRStore, time: any TimeSource,
                recogniserName: String = VisionTextRecogniser.descriptor) {
        self.pictures = pictures
        self.recogniser = recogniser
        self.ocr = ocr
        self.time = time
        self.recogniserName = recogniserName
    }

    public func run(_ job: AnalysisJobRecord, attempt: Int) async -> JobOutcome {
        guard let imageID = job.imageId else { return .permanent("picture no longer stored") }
        let forced = job.kind == Self.forceKind
        do {
            try await read(imageID: imageID, forced: forced)
        } catch let error as PipelineError {
            return JobOutcome(error)
        } catch {
            return .transient("text recognition failed")
        }
        return .success
    }

    private func read(imageID: String, forced: Bool) async throws {
        if !forced, (try? ocr.isRead(imageID: imageID)) == true { return }
        guard let picture = try? pictures.fullPicture(imageID: imageID) else { throw PipelineError.permanent("picture no longer stored") }
        let started = time.now()
        let lines: [RecognisedLine]
        do { lines = try await recogniser.recognise(picture) } catch { throw PipelineError.transient("text recognition failed") }
        let ms = max(0, Int((time.now().timeIntervalSince(started) * 1000).rounded()))
        do { try ocr.save(imageID: imageID, lines: lines, durationMs: ms, recogniser: recogniserName, at: time.now()) }
        catch { throw PipelineError.transient("text recognition failed") }
        Self.logger.info("read image=\(imageID, privacy: .public) lines=\(lines.count) ms=\(ms)")
    }
}
