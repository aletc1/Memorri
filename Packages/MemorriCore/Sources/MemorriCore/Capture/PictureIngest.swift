import CoreGraphics
import Foundation
import ImageIO

public enum PictureIngestError: Error, Sendable, Equatable {
    case notAPicture
    case couldNotSave
}

/// Stores a picture from a file as if it had been captured: both HEIC copies, one event and one image row. Used by the
/// Debug launch switch and by tests, so a synthetic picture can go through the real analysis without the screen.
public struct PictureIngest: Sendable {
    private let paths: AppPaths
    private let files: CaptureFileStore
    private let store: any CaptureStoring
    private let encoder: any ImageEncoding
    private let modelLongEdge: Int
    private let time: any TimeSource

    public init(paths: AppPaths, files: CaptureFileStore, store: any CaptureStoring, encoder: any ImageEncoding = HEICImageEncoder(),
                modelLongEdge: Int, time: any TimeSource = SystemTimeSource()) {
        self.paths = paths
        self.files = files
        self.store = store
        self.encoder = encoder
        self.modelLongEdge = modelLongEdge
        self.time = time
    }

    /// Returns the new image id. Nothing is left behind when it throws.
    @discardableResult
    public func store(png: Data, windows: [WindowInfo] = [], capturedAt takenAt: Date? = nil) throws -> String {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PictureIngestError.notAPicture }

        let full: EncodedPicture, model: EncodedPicture
        do {
            full = try encoder.encodeFullResolution(image)
            model = try encoder.encodeAnalysisCopy(image, longEdge: modelLongEdge)
        } catch { throw PictureIngestError.couldNotSave }

        let eventID = UUID().uuidString, imageID = UUID().uuidString
        let capturedAt = takenAt ?? time.now()
        let staging: URL
        var committed = false
        do {
            try paths.prepare()
            staging = try files.makeStagingDirectory()
        } catch { throw PictureIngestError.couldNotSave }
        do {
            let fullName = "\(imageID)-full.heic", modelName = "\(imageID)-model.heic"
            try full.data.write(to: staging.appendingPathComponent(fullName))
            try model.data.write(to: staging.appendingPathComponent(modelName))
            let base = "captures/\(CaptureFileStore.monthFolder(for: capturedAt))/\(eventID)"
            let record = CaptureImageRecord(id: imageID, eventId: eventID, displayId: 0, displayName: "Ingested picture",
                                            pixelWidth: full.width, pixelHeight: full.height, scale: 1,
                                            fullPath: "\(base)/\(fullName)", modelPath: "\(base)/\(modelName)",
                                            modelWidth: model.width, modelHeight: model.height,
                                            fullBytes: full.data.count, modelBytes: model.data.count, missing: false)
            _ = try files.commit(staging: staging, eventID: eventID, capturedAt: capturedAt)
            committed = true
            let event = CaptureEventRecord(id: eventID, capturedAt: capturedAt, trigger: CaptureTrigger.menu.rawValue, status: "complete",
                                           failureReason: nil, displayCount: 1)
            try store.insert(event: event, images: [record], windows: windows.isEmpty ? [:] : [imageID: windows])
            return imageID
        } catch {
            files.discard(staging: staging)
            if committed { files.removeCaptureDirectory(eventID: eventID, capturedAt: capturedAt) }
            throw PictureIngestError.couldNotSave
        }
    }
}
