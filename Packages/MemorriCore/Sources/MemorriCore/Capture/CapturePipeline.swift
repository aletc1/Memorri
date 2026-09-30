import Foundation
import os

/// One capture run: free-space check, capture every display, encode, stage, commit, record.
/// Nothing half-written survives a failure (ADR 0009). One run at a time (FR-011).
public actor CapturePipeline {
    /// Below this the app refuses to capture (FR-022).
    public static let minimumFreeBytes: Int64 = 1_073_741_824

    static let notEnoughSpace = "Not enough free disk space"
    static let noDisplay = "no display available"
    static let couldNotSave = "could not save the pictures"

    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "capture")

    private let capturer: any DisplayCapturing
    private let encoder: any ImageEncoding
    private let disk: any DiskSpaceChecking
    private let files: CaptureFileStore
    private let store: any CaptureStoring
    private let paths: AppPaths
    private let settings: StorageSettings
    private let time: any TimeSource
    private let enqueuer: (any AnalysisEnqueuing)?
    private let analysisSettings: AnalysisSettings?

    private var isRunning = false

    public init(capturer: any DisplayCapturing, encoder: any ImageEncoding, disk: any DiskSpaceChecking,
                files: CaptureFileStore, store: any CaptureStoring, paths: AppPaths,
                settings: StorageSettings, time: any TimeSource = SystemTimeSource(),
                enqueuer: (any AnalysisEnqueuing)? = nil, analysisSettings: AnalysisSettings? = nil) {
        self.capturer = capturer
        self.encoder = encoder
        self.disk = disk
        self.files = files
        self.store = store
        self.paths = paths
        self.settings = settings
        self.time = time
        self.enqueuer = enqueuer
        self.analysisSettings = analysisSettings
    }

    /// `nil` when another capture is already running.
    public func run(trigger: CaptureTrigger) async -> CaptureOutcome? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        let started = ContinuousClock.now
        let eventID = UUID().uuidString
        let capturedAt = time.now()

        func fail(_ reason: String, recordedReason: String? = nil, displays: Int = 0) -> CaptureOutcome {
            recordFailure(id: eventID, at: capturedAt, trigger: trigger, reason: recordedReason ?? reason, displays: displays)
            Self.logger.notice("capture refused reason=\(reason, privacy: .public)")
            return .failed(reason: reason)
        }

        do { try paths.prepare() } catch {
            return fail(Self.couldNotSave)
        }

        if let free = try? disk.freeBytes(at: paths.root), free < Self.minimumFreeBytes {
            return fail(Self.notEnoughSpace)
        }

        let result: DisplayCaptureResult
        do {
            result = try await capturer.captureAllDisplays()
        } catch CaptureFailure.permissionDenied {
            recordFailure(id: eventID, at: capturedAt, trigger: trigger, reason: "permission denied", displays: 0)
            Self.logger.notice("capture finished status=failed displays=0 images=0 ms=\(Self.milliseconds(since: started)) permission=denied")
            return .permissionDenied
        } catch CaptureFailure.noDisplays {
            return fail(Self.noDisplay)
        } catch CaptureFailure.other(let message) {
            return fail(message)
        } catch {
            return fail(error.localizedDescription)
        }

        let attempted = result.displays.count + result.failedDisplayCount
        guard !result.displays.isEmpty else { return fail(Self.noDisplay, displays: attempted) }

        let longEdge = settings.modelLongEdge
        let encoded: [(display: CapturedDisplay, full: EncodedPicture, model: EncodedPicture)]
        do {
            encoded = try await encodeAll(result.displays, longEdge: longEdge)
        } catch {
            return fail(Self.couldNotSave, displays: attempted)
        }

        let staging: URL
        var committed: URL?
        do {
            staging = try files.makeStagingDirectory()
        } catch {
            return fail(Self.couldNotSave, displays: attempted)
        }

        do {
            var images: [CaptureImageRecord] = []
            let folder = CaptureFileStore.monthFolder(for: capturedAt)
            for item in encoded {
                let imageID = UUID().uuidString
                let fullName = "\(imageID)-full.heic", modelName = "\(imageID)-model.heic"
                try item.full.data.write(to: staging.appendingPathComponent(fullName))
                try item.model.data.write(to: staging.appendingPathComponent(modelName))
                let base = "captures/\(folder)/\(eventID)"
                images.append(CaptureImageRecord(
                    id: imageID, eventId: eventID, displayId: Int(item.display.displayID),
                    displayName: item.display.name, pixelWidth: item.full.width, pixelHeight: item.full.height,
                    scale: item.display.scale, fullPath: "\(base)/\(fullName)", modelPath: "\(base)/\(modelName)",
                    modelWidth: item.model.width, modelHeight: item.model.height,
                    fullBytes: item.full.data.count, modelBytes: item.model.data.count, missing: false))
            }
            committed = try files.commit(staging: staging, eventID: eventID, capturedAt: capturedAt)

            let partial = result.failedDisplayCount > 0
            let event = CaptureEventRecord(
                id: eventID, capturedAt: capturedAt, trigger: trigger.rawValue,
                status: partial ? "partial" : "complete",
                failureReason: partial ? "\(result.failedDisplayCount) of \(attempted) displays could not be captured" : nil,
                displayCount: attempted)
            try store.insert(event: event, images: images)

            let status = partial ? "partial" : "complete"
            Self.logger.notice("capture finished status=\(status, privacy: .public) displays=\(attempted) images=\(images.count) ms=\(Self.milliseconds(since: started))")
            // The capture is done and stored; queueing its analysis can never turn it into a failure.
            if let enqueuer, analysisSettings?.automatic ?? true { await enqueuer.enqueueAnalysis(imageIDs: images.map(\.id)) }
            return partial ? .partial(captured: result.displays.count, of: attempted) : .complete(displays: attempted)
        } catch {
            files.discard(staging: staging)
            if committed != nil { files.removeCaptureDirectory(eventID: eventID, capturedAt: capturedAt) }
            return fail(Self.couldNotSave, displays: attempted)
        }
    }

    private func encodeAll(_ displays: [CapturedDisplay], longEdge: Int) async throws
        -> [(display: CapturedDisplay, full: EncodedPicture, model: EncodedPicture)] {
        let encoder = self.encoder
        return try await withThrowingTaskGroup(of: (Int, EncodedPicture, EncodedPicture).self) { group in
            for (index, display) in displays.enumerated() {
                group.addTask {
                    (index, try encoder.encodeFullResolution(display.image),
                     try encoder.encodeAnalysisCopy(display.image, longEdge: longEdge))
                }
            }
            var byIndex: [Int: (EncodedPicture, EncodedPicture)] = [:]
            for try await (index, full, model) in group { byIndex[index] = (full, model) }
            return displays.enumerated().map { ($1, byIndex[$0]!.0, byIndex[$0]!.1) }
        }
    }

    /// A failed attempt is recorded when the store allows it (FR-003); a store failure is not fatal here.
    private func recordFailure(id: String, at date: Date, trigger: CaptureTrigger, reason: String, displays: Int) {
        let event = CaptureEventRecord(id: id, capturedAt: date, trigger: trigger.rawValue, status: "failed",
                                       failureReason: reason, displayCount: displays)
        try? store.insert(event: event, images: [])
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let parts = (ContinuousClock.now - start).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
