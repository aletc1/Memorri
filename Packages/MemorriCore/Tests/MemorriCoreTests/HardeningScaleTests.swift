import CryptoKit
import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Hardening stays cheap on a big library (spec 010 SC-007 and the plan's performance goals).
@Suite struct HardeningScaleTests {
    @Test func checkingACaptureAgainstTenThousandItemsTakesUnderAHundredMilliseconds() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.addContext("ctx-a", "Customer A")
        let earlier = try f.addPicture(at: ReconcileFixture.nine.addingTimeInterval(-86_400))
        let later = try f.addPicture(at: ReconcileFixture.nine)
        try f.save([], imageID: earlier, contextID: "ctx-a")
        try f.save([], imageID: later, contextID: "ctx-a")
        let detector = CancellationDetector(database: f.database, now: { Date(timeIntervalSince1970: 1_800_100_000) })
        // The earlier capture covered the week and showed every item; 10,000 items in the library, 40 of them in the stretch the new capture covers.
        _ = try detector.record(imageID: earlier, coverage: [CoverageDraft(windowKey: "w", kind: .calendarWeek, spans: [DateInterval(start: ReconcileFixture.minutes(-6000), end: ReconcileFixture.minutes(90_000))])])
        // 10,000 rows in one statement each: the first 40 start in the covered stretch (10 minutes apart from 07:00), the rest long after it.
        let nine = Int(ReconcileFixture.nine.timeIntervalSince1970), seen = Int(ReconcileFixture.nine.timeIntervalSince1970) - 86_400
        try await f.database.pool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 9999)
                INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at, start_at, end_at, context_id, all_day)
                SELECT 'i' || i, 'appointment', 'event', 'active', 'Item ' || i, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'),
                       strftime('%Y-%m-%d %H:%M:%f', CASE WHEN i < 40 THEN \(nine) + i * 600 ELSE \(nine) + (2000 + i * 7) * 60 END, 'unixepoch'),
                       strftime('%Y-%m-%d %H:%M:%f', (CASE WHEN i < 40 THEN \(nine) + i * 600 ELSE \(nine) + (2000 + i * 7) * 60 END) + 1800, 'unixepoch'), 'ctx-a', 0 FROM n
                """)
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 9999)
                INSERT INTO sightings (id, item_id, image_id, finding_id, captured_at, title, cited_lines_json, confidence, decision_json, created_at)
                SELECT 's' || i, 'i' || i, '\(earlier)', 'f', strftime('%Y-%m-%d %H:%M:%f', \(seen), 'unixepoch'), 'Item ' || i, '[1]', 0.9, '{}', datetime('now') FROM n
                """)
        }
        var best = Double.infinity
        for _ in 0..<3 {
            let started = Date()
            _ = try detector.record(imageID: later, coverage: [CoverageDraft(windowKey: "w", kind: .calendarWeek, spans: [DateInterval(start: ReconcileFixture.minutes(-60), end: ReconcileFixture.minutes(500))])])
            best = min(best, Date().timeIntervalSince(started))
        }
        let absences = try f.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cancel_absences WHERE image_id = ?", arguments: [later]) }
        #expect(absences == 40)                                                         // only the items of the covered stretch
        #expect(best < 0.1, "took \(best) s")
    }

    @Test func aBackupOfAFewHundredMegabytesIsFastAndScalesToAGigabyteWithinTwoMinutes() async throws {
        let f = try makePipelineFixture(); defer { f.cleanUp() }
        // 256 MB of pictures in 64 files of 4 MB (a quarter of the 1 GB of SC-007, so the limit is a quarter of two minutes).
        let folder = f.paths.captures.appendingPathComponent("bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let block = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for n in 0..<64 { try block.write(to: folder.appendingPathComponent("p\(n).heic")) }
        let destination = f.temp.url.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let backup = LibraryBackup(database: f.database, paths: f.paths, availableSpace: { _ in nil })
        let started = Date()
        let (package, manifest) = try await backup.make(into: destination, includePictures: true)
        let elapsed = Date().timeIntervalSince(started)
        #expect(manifest.files.count > 64 && FileManager.default.fileExists(atPath: package.path))
        #expect(elapsed < 30, "256 MB took \(elapsed) s")
    }
}
