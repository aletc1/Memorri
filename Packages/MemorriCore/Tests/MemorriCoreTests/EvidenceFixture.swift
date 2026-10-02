import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import MemorriCore

/// Items with sightings on real (drawn) pictures and read lines, to cut evidence from.
final class EvidenceFixture {
    let fixture: ReconcileFixture
    let provider: StoredPictureProvider
    let judge = NoMeaningJudge()
    var paths: AppPaths { fixture.base.paths }
    var database: StorageDatabase { fixture.database }

    /// Lines of the drawn pictures (1200 x 600): the title and time of one block, and a line far away.
    static let lines: [RecognisedLine] = [
        RecognisedLine(n: 1, text: "Daily standup", box: PixelBox(x: 100, y: 100, width: 300, height: 30), confidence: 0.9),
        RecognisedLine(n: 2, text: "09:00", box: PixelBox(x: 100, y: 140, width: 80, height: 30), confidence: 0.9),
        RecognisedLine(n: 3, text: "Elsewhere", box: PixelBox(x: 800, y: 500, width: 300, height: 40), confidence: 0.9),
    ]

    init() throws {
        fixture = try ReconcileFixture()
        provider = StoredPictureProvider(paths: fixture.base.paths, store: fixture.base.captures)
    }

    func cleanUp() { fixture.cleanUp() }

    func writer(encoder: any ImageEncoding = HEICImageEncoder()) -> EvidenceWriter {
        EvidenceWriter(paths: paths, database: database, pictures: provider, encoder: encoder, now: { Date(timeIntervalSince1970: 1_791_999_000) })
    }

    func store() -> EvidenceStore { EvidenceStore(database: database, paths: paths, pictures: provider) }

    func reconciler() -> Reconciler {
        Reconciler(database: database, judge: judge, now: { Date(timeIntervalSince1970: 1_791_999_000) })
    }

    /// A new picture with files on disk, taken at `date`; its id.
    func addStoredPicture(at date: Date) throws -> String {
        let event = makeEventRecord(at: date)
        var image = makeImageRecord(eventID: event.id)
        image.pixelWidth = 1200; image.pixelHeight = 600; image.modelWidth = 600; image.modelHeight = 300
        for (path, size) in [(image.fullPath, (1200, 600)), (image.modelPath, (600, 300))] {
            let url = paths.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeHEICData(width: size.0, height: size.1).write(to: url)
        }
        try fixture.base.captures.insert(event: event, images: [image])
        return image.id
    }

    /// Stores the read lines and the findings of `imageID` and reconciles it (what the analyse job does before evidence).
    @discardableResult
    func see(_ findings: [Finding], imageID: String? = nil, lines: [RecognisedLine] = EvidenceFixture.lines,
             windows: [WindowReadingRecord] = []) async throws -> String {
        let id = imageID ?? fixture.base.imageID
        try OCRStore(database: database).save(imageID: id, lines: lines, durationMs: 1, recogniser: "test", at: Date(timeIntervalSince1970: 1_791_950_000))
        try fixture.save(findings, imageID: id)
        // after the analysis, which replaces a picture's window readings with its own (none here)
        if !windows.isEmpty { try WindowReadingStore(database: database).save(imageID: id, readings: windows) }
        _ = await reconciler().reconcile(imageID: id)
        return id
    }

    /// A finding that sits in the window `key`.
    func windowed(_ base: Finding, key: String) -> Finding {
        Finding(id: base.id, kind: base.kind, title: base.title, allDay: base.allDay, start: base.start, end: base.end, timezone: base.timezone,
                citedLines: base.citedLines, confidence: base.confidence, provenance: base.provenance, windowKey: key)
    }

    /// What the windows step stored about a window of `imageID`.
    func window(_ key: String, app: String?, title: String?, frame: PixelBox, imageID: String? = nil) -> WindowReadingRecord {
        WindowReadingRecord(imageID: imageID ?? fixture.base.imageID, windowKey: key, appName: app, title: title, frame: frame, visible: [frame],
                            visibleShare: 1, relevant: true, kind: .calendarWeek, confidence: 0.9, remote: false, runID: nil,
                            promptVersion: "windows-v1", createdAt: Date(timeIntervalSince1970: 1_791_950_000))
    }

    func evidenceRows(imageID: String? = nil) throws -> [Row] {
        try fixture.read { db in
            if let imageID { return try Row.fetchAll(db, sql: "SELECT * FROM evidence WHERE image_id = ? ORDER BY captured_at, id", arguments: [imageID]) }
            return try Row.fetchAll(db, sql: "SELECT * FROM evidence ORDER BY captured_at, id")
        }
    }

    func decodedSize(_ relativePath: String) -> (Int, Int)? {
        let url = paths.root.appendingPathComponent(relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    func mode(_ relativePath: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: paths.root.appendingPathComponent(relativePath).path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func fileExists(_ relativePath: String) -> Bool { FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(relativePath).path) }
}
