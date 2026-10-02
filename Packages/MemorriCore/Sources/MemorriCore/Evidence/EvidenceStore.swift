import CoreGraphics
import Foundation
import GRDB
import ImageIO

/// The visual proof of one sighting: a saved cut-out of the capture around the lines the finding cited. It stays while its item
/// exists, also after the capture is gone, so it keeps copies of the sighting's details (spec 006, research R3).
public struct EvidenceRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let itemID: String
    public let sightingID: String?
    public let imageID: String
    public let capturedAt: Date
    public let displayName: String?
    public let title: String
    public let citedLines: [Int]
    public let region: PixelRegion?
    /// Relative to the app root; nil when there is no cut-out, and then `reason` says why.
    public let filePath: String?
    /// `no-lines`, `picture-missing` or `failed` when there is no cut-out.
    public let reason: String?
    /// The window the finding came from (application and title), when the capture was read by window.
    public var windowApp: String? = nil
    public var windowTitle: String? = nil
}

/// Reads evidence rows, their images and the whole capture behind them.
public struct EvidenceStore: Sendable {
    let database: StorageDatabase
    let paths: AppPaths
    let pictures: (any FullPictureProviding)?

    public init(database: StorageDatabase, paths: AppPaths, pictures: (any FullPictureProviding)? = nil) {
        self.database = database; self.paths = paths; self.pictures = pictures
    }

    /// Newest first.
    public func evidence(itemID: String) throws -> [EvidenceRecord] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM evidence WHERE item_id = ? ORDER BY captured_at DESC, id", arguments: [itemID]).map(Self.record(from:))
        }
    }

    /// The saved cut-out, nil when there is none or its file is gone.
    public func image(_ record: EvidenceRecord) -> CGImage? {
        guard let path = record.filePath else { return nil }
        let url = paths.root.appendingPathComponent(path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The whole capture with its text lines (for outlining the cited ones); nil once the picture is no longer stored.
    public func capture(_ record: EvidenceRecord) throws -> (picture: CGImage, lines: [RecognisedLine])? {
        try capture(imageID: record.imageID)
    }

    public func capture(imageID: String) throws -> (picture: CGImage, lines: [RecognisedLine])? {
        guard let pictures, let picture = try pictures.fullPicture(imageID: imageID) else { return nil }
        return (picture, try OCRStore(database: database).lines(imageID: imageID))
    }

    /// What the evidence files take, from the rows (the files themselves are counted by `StorageStats`).
    public func totalBytes() throws -> Int64 {
        try database.pool.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(bytes), 0) FROM evidence") ?? 0 }
    }

    static func record(from row: Row) -> EvidenceRecord {
        let decoder = JSONDecoder()
        let cited = (row["cited_lines_json"] as String?).flatMap { try? decoder.decode([Int].self, from: Data($0.utf8)) } ?? []
        let region = (row["region_json"] as String?).flatMap { try? decoder.decode(PixelRegion?.self, from: Data($0.utf8)) } ?? nil
        return EvidenceRecord(id: row["id"], itemID: row["item_id"], sightingID: row["sighting_id"], imageID: row["image_id"],
                              capturedAt: row["captured_at"], displayName: row["display_name"], title: row["title"], citedLines: cited,
                              region: region, filePath: row["file_path"], reason: row["reason"],
                              windowApp: row["window_app"], windowTitle: row["window_title"])
    }
}
