import CoreGraphics
import Foundation
import GRDB
import os

/// What the analyse job calls after reconciling a picture; a fake in tests.
public protocol ImageEvidenceWriting: Sendable {
    @discardableResult func write(imageID: String) async -> Int
}

/// Cuts the proof of each sighting out of the full-size picture and saves it (spec 006, research R1 to R3). Failures are logged and
/// leave a row that says why there is no cut-out; they never reach the analysis job.
public struct EvidenceWriter: ImageEvidenceWriting {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "evidence")

    let paths: AppPaths
    let database: StorageDatabase
    let pictures: any FullPictureProviding
    let encoder: any ImageEncoding
    let now: @Sendable () -> Date

    public init(paths: AppPaths, database: StorageDatabase, pictures: any FullPictureProviding, encoder: any ImageEncoding = HEICImageEncoder(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths; self.database = database; self.pictures = pictures; self.encoder = encoder; self.now = now
    }

    private struct Target {
        let sightingID: String, itemID: String, imageID: String, title: String, capturedAt: Date, cited: [Int], displayName: String?
    }

    /// Replaces the picture's evidence with one entry per sighting it has now. Returns how many cut-outs were saved.
    @discardableResult
    public func write(imageID: String) async -> Int {
        let started = ContinuousClock.now
        do {
            let targets = try self.targets(where: "s.image_id = ?", arguments: [imageID])
            let old = try oldEvidence(imageID: imageID)
            let (saved, skipped) = try cut(targets, imageID: imageID, allowMissingRows: true, replacing: old.map(\.id))
            for row in old { remove(file: row.path) }
            let elapsed = started.duration(to: .now).components
            Self.logger.info("evidence image=\(imageID, privacy: .public) written=\(saved) skipped=\(skipped) ms=\(Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))")
            return saved
        } catch {
            Self.logger.error("evidence failed image=\(imageID, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
    }

    /// Cut-outs for the sightings of one item that have none and whose picture is stored, and new ones for cut-outs of an older shape.
    @discardableResult
    public func backfill(itemID: String) async -> Int {
        let remade = await remake(where: "item_id = ?", arguments: [itemID], limit: nil)
        return await backfill(where: "s.item_id = ?", arguments: [itemID], limit: nil) + remade
    }

    /// The same for the newest sightings of any item, at most `limit` of them (a launch pass).
    @discardableResult
    public func backfill(limit: Int) async -> Int {
        let remade = await remake(where: "1 = 1", arguments: [], limit: limit)
        let written = await backfill(where: "1 = 1", arguments: [], limit: limit) + remade
        if written > 0 { Self.logger.info("evidence backfill written=\(written)") }
        return written
    }

    /// Makes the cut-outs of an older shape again, for the pictures that are still stored (a picture that is gone keeps its old cut-out).
    private func remake(where clause: String, arguments: StatementArguments, limit: Int?) async -> Int {
        do {
            let images = try outdatedImages(where: clause, arguments: arguments)
            var written = 0
            for image in images.prefix(limit ?? images.count) where (try? pictures.fullPicture(imageID: image)) != nil {
                written += await write(imageID: image)
            }
            return written
        } catch {
            Self.logger.error("evidence failed remake reason=\(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
    }

    private func backfill(where clause: String, arguments: StatementArguments, limit: Int?) async -> Int {
        do {
            let all = try targets(where: "\(clause) AND NOT EXISTS (SELECT 1 FROM evidence e WHERE e.sighting_id = s.id)", arguments: arguments)
            let limited = limit.map { Array(all.prefix($0)) } ?? all
            var written = 0
            for (imageID, group) in Dictionary(grouping: limited, by: \.imageID) {
                written += try cut(group, imageID: imageID, allowMissingRows: false, replacing: []).saved
            }
            return written
        } catch {
            Self.logger.error("evidence failed backfill reason=\(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
    }

    /// The pictures with a cut-out of an older shape, newest first. A plain function: inside an async one `pool.read` would pick the async overload.
    private func outdatedImages(where clause: String, arguments: StatementArguments) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT image_id FROM evidence WHERE geometry < ? AND file_path IS NOT NULL AND \(clause)
                GROUP BY image_id ORDER BY MAX(captured_at) DESC
                """, arguments: StatementArguments([EvidenceGeometry.version]) + arguments)
        }
    }

    private func oldEvidence(imageID: String) throws -> [(id: String, path: String?)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, file_path FROM evidence WHERE image_id = ?", arguments: [imageID]).map { ($0["id"], $0["file_path"]) }
        }
    }

    private func targets(where clause: String, arguments: StatementArguments) throws -> [Target] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.item_id, s.image_id, s.title, s.captured_at, s.cited_lines_json, i.display_name
                FROM sightings s LEFT JOIN capture_images i ON i.id = s.image_id
                WHERE \(clause) ORDER BY s.captured_at DESC, s.id
                """, arguments: arguments).map { row in
                Target(sightingID: row["id"], itemID: row["item_id"], imageID: row["image_id"], title: row["title"], capturedAt: row["captured_at"],
                       cited: (try? JSONDecoder().decode([Int].self, from: Data((row["cited_lines_json"] as String).utf8))) ?? [],
                       displayName: row["display_name"])
            }
        }
    }

    /// One picture: decode it once, cut every target, save the files, then replace the rows in one transaction.
    private func cut(_ targets: [Target], imageID: String, allowMissingRows: Bool, replacing old: [String]) throws -> (saved: Int, skipped: Int) {
        guard !targets.isEmpty || !old.isEmpty else { return (0, 0) }
        let picture = try? pictures.fullPicture(imageID: imageID)
        if picture == nil && !allowMissingRows { return (0, targets.count) }
        let lines = Dictionary(uniqueKeysWithValues: try OCRStore(database: database).lines(imageID: imageID).map { ($0.n, $0.box) })
        var rows: [(id: String, target: Target, region: PixelRegion?, path: String?, reason: String?, bytes: Int)] = []
        var written: [URL] = []
        var saved = 0, skipped = 0
        for target in targets {
            let id = UUID().uuidString
            guard let picture else { rows.append((id, target, nil, nil, "picture-missing", 0)); skipped += 1; continue }
            let boxes = target.cited.compactMap { lines[$0] }
            guard let region = EvidenceGeometry.region(lines: boxes, pictureWidth: picture.width, pictureHeight: picture.height) else {
                rows.append((id, target, nil, nil, "no-lines", 0)); skipped += 1; continue
            }
            do {
                let (path, bytes, url) = try save(cutOut(of: picture, region: region), id: id, capturedAt: target.capturedAt)
                written.append(url)
                rows.append((id, target, region, path, nil, bytes)); saved += 1
            } catch {
                Self.logger.error("evidence failed image=\(imageID, privacy: .public) reason=\(String(describing: type(of: error)), privacy: .public)")
                rows.append((id, target, region, nil, "failed", 0)); skipped += 1
            }
        }
        let date = now()
        do {
            try database.pool.write { db in
                for id in old { try db.execute(sql: "DELETE FROM evidence WHERE id = ?", arguments: [id]) }
                for row in rows {
                    let regionJSON = (try? JSONEncoder().encode(row.region)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
                    let cited = (try? JSONEncoder().encode(row.target.cited)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                    try db.execute(sql: """
                        INSERT INTO evidence (id, item_id, sighting_id, image_id, captured_at, display_name, title, cited_lines_json, region_json,
                                              file_path, reason, bytes, created_at, geometry)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, row.target.itemID, row.target.sightingID, imageID, row.target.capturedAt, row.target.displayName,
                                         row.target.title, cited, regionJSON, row.path, row.reason, row.bytes, date, EvidenceGeometry.version])
                }
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return (saved, skipped)
    }

    private func cutOut(of picture: CGImage, region: PixelRegion) throws -> EncodedPicture {
        guard let cropped = picture.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) else {
            throw ImageEncodingError.cannotScale
        }
        let size = EvidenceGeometry.outputSize(for: region)
        return try encoder.encodeAnalysisCopy(cropped, longEdge: max(size.width, size.height))
    }

    private func save(_ encoded: EncodedPicture, id: String, capturedAt: Date) throws -> (path: String, bytes: Int, url: URL) {
        let relative = "evidence/\(CaptureFileStore.monthFolder(for: capturedAt))/\(id).heic"
        let url = paths.root.appendingPathComponent(relative)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoded.data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (relative, encoded.data.count, url)
    }

    private func remove(file path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(at: paths.root.appendingPathComponent(path))
    }
}
