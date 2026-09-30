import Foundation

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

/// Reads analysis copies from the capture folder (spec 002).
public struct StoredPictureProvider: AnalysisPictureProviding {
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
}
