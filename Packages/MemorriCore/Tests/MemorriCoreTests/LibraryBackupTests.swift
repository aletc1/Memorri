import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// A backup of the library: consistent, complete, checked, and never half written (spec 010 FR-017, FR-018).
@Suite struct LibraryBackupTests {
    private let when = Date(timeIntervalSince1970: 1_800_100_000)

    struct Rig {
        let fixture: PipelineFixture
        let backup: LibraryBackup
        let folder: URL
        var paths: AppPaths { fixture.paths }
    }

    private func rig(items: Int = 3, space: (@Sendable (URL) -> Int64?)? = nil) throws -> Rig {
        let fixture = try makePipelineFixture()
        try fixture.database.pool.write { db in
            for n in 0..<items {
                try db.execute(sql: """
                    INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                    VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                    """, arguments: ["i\(n)", "Item \(n)"])
            }
        }
        try FileManager.default.createDirectory(at: fixture.paths.evidence, withIntermediateDirectories: true)
        try Data("cut-out one".utf8).write(to: fixture.paths.evidence.appendingPathComponent("e1.png"))
        let folder = fixture.temp.url.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Rig(fixture: fixture, backup: LibraryBackup(database: fixture.database, paths: fixture.paths, appVersion: "1.2.3", availableSpace: space ?? { _ in nil }), folder: folder)
    }

    private func contents(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    @Test func aBackupHoldsASnapshotOfTheDatabaseTheCutOutsAndThePicturesWithAManifestThatChecks() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        var reported: [Double] = []
        let box = Box()
        let (package, manifest) = try await r.backup.make(into: r.folder, includePictures: true, now: when, progress: { box.add($0) })
        reported = box.values
        #expect(package.pathExtension == "memorribackup" && contents(r.folder) == [package.lastPathComponent])
        #expect(manifest.includesPictures && manifest.app == "1.2.3" && manifest.format == 1 && !manifest.schema.isEmpty)
        let names = manifest.files.map(\.path)
        #expect(names.contains("memorri.sqlite") && names.contains("evidence/e1.png") && names.contains { $0.hasPrefix("captures/") })
        #expect(reported.last == 1 && reported == reported.sorted())
        for file in manifest.files {
            let url = package.appendingPathComponent(file.path)
            let hash = try LibraryBackup.sha256(of: url)
            #expect(LibraryBackup.size(ofFileAt: url.path) == file.size && hash == file.sha256)
        }
        #expect(try LibraryRestore(paths: r.paths).validate(package) == manifest)
        let copy = try DatabaseQueue(path: package.appendingPathComponent("memorri.sqlite").path)
        let count = try await copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }
        #expect(count == 3)
    }

    @Test func withoutPicturesTheCapturesAreLeftOutAndBothSizesAreKnownBeforehand() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let sizes = r.backup.sizes()
        #expect(sizes.withPictures > sizes.withoutPictures)
        #expect(sizes.withPictures - sizes.withoutPictures == StorageStats.bytes(under: r.paths.captures))
        let (_, manifest) = try await r.backup.make(into: r.folder, includePictures: false, now: when)
        #expect(!manifest.includesPictures && !manifest.files.contains { $0.path.hasPrefix("captures/") } && manifest.files.contains { $0.path.hasPrefix("evidence/") })
    }

    @Test func aCancelledBackupLeavesNothingBehind() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let task = Task { try await r.backup.make(into: r.folder, includePictures: true, now: when) }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { Issue.record("a cancelled backup should fail"); return }
        #expect(error as? BackupError == .cancelled)
        #expect(contents(r.folder).isEmpty)
    }

    @Test func notEnoughSpaceIsRefusedBeforeAnythingIsWritten() async throws {
        let r = try rig(space: { _ in 10 }); defer { r.fixture.cleanUp() }
        do { _ = try await r.backup.make(into: r.folder, includePictures: true, now: when); Issue.record("expected a refusal") }
        catch let error as BackupError {
            guard case .notEnoughSpace(let needed, let available) = error else { Issue.record("wrong error \(error)"); return }
            #expect(needed > 0 && available == 10 && !error.message.isEmpty)
        }
        #expect(contents(r.folder).isEmpty)
    }

    @Test func theSnapshotIsWholeWhileTheAppKeepsWriting() async throws {
        let r = try rig(items: 50); defer { r.fixture.cleanUp() }
        let writer = Task {
            for n in 0..<300 {
                try? await r.fixture.database.pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                        VALUES (?, 'appointment', 'event', 'active', 'Later', 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                        """, arguments: ["w\(n)"])
                }
            }
        }
        let (package, _) = try await r.backup.make(into: r.folder, includePictures: false, now: when)
        await writer.value
        var configuration = Configuration(); configuration.readonly = true
        let copy = try DatabaseQueue(path: package.appendingPathComponent("memorri.sqlite").path, configuration: configuration)
        let check = try await copy.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        let count = try await copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") } ?? 0
        #expect(check == "ok" && count >= 50 && count <= 350)
    }

    @Test func twoBackupsAtTheSameSecondGetTheirOwnNames() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let first = try await r.backup.make(into: r.folder, includePictures: false, now: when).package
        let second = try await r.backup.make(into: r.folder, includePictures: false, now: when).package
        #expect(first != second && contents(r.folder).count == 2)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ value: Double) { lock.withLock { items.append(value) } }
    var values: [Double] { lock.withLock { items } }
}
