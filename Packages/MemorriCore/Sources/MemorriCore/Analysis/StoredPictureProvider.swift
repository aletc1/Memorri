import CoreGraphics
import Foundation
import ImageIO

/// An analysis copy read from disk, in the format it was stored in (HEIC).
public struct StoredPicture: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int
    public var longEdge: Int { max(width, height) }

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

public protocol AnalysisPictureProviding: Sendable {
    /// The analysis copy of a stored picture, or nil when it is no longer stored.
    func analysisPicture(imageID: String) throws -> StoredPicture?
}

public protocol FullPictureProviding: Sendable {
    /// The full-resolution picture decoded, or nil when it is no longer stored or cannot be decoded.
    func fullPicture(imageID: String) throws -> CGImage?
}

/// Reads analysis copies and full-resolution pictures from the capture folder (spec 002).
public struct StoredPictureProvider: AnalysisPictureProviding, FullPictureProviding {
    private let paths: AppPaths
    private let store: CaptureStore

    public init(paths: AppPaths, store: CaptureStore) {
        self.paths = paths
        self.store = store
    }

    public func analysisPicture(imageID: String) throws -> StoredPicture? {
        guard let record = try store.image(id: imageID), !record.missing else { return nil }
        let url = paths.root.appendingPathComponent(record.modelPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return StoredPicture(data: data, width: record.modelWidth, height: record.modelHeight)
    }

    public func fullPicture(imageID: String) throws -> CGImage? {
        guard let record = try store.image(id: imageID), !record.missing else { return nil }
        let url = paths.root.appendingPathComponent(record.fullPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
