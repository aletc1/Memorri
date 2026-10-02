import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Restoring a backup: validated, staged, swapped at the next start, with a safety copy, and nothing lost on any failure (spec 010 FR-019 to FR-021).
@Suite struct LibraryRestoreTests {
    private let when = Date(timeIntervalSince1970: 1_800_100_000)

    struct Rig {
        let fixture: PipelineFixture
        let backup: LibraryBackup
        let folder: URL
        var paths: AppPaths { fixture.paths }
        var restore: LibraryRestore { LibraryRestore(paths: fixture.paths) }
    }

    private func rig() throws -> Rig {
        let fixture = try makePipelineFixture()
        try addItems(fixture, ["Standup", "Budget review"])
        try FileManager.default.createDirectory(at: fixture.paths.evidence, withIntermediateDirectories: true)
        try Data("cut-out one".utf8).write(to: fixture.paths.evidence.appendingPathComponent("e1.png"))
        let folder = fixture.temp.url.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Rig(fixture: fixture, backup: LibraryBackup(database: fixture.database, paths: fixture.paths, appVersion: "1", availableSpace: { _ in nil }), folder: folder)
    }

    private func addItems(_ fixture: PipelineFixture, _ titles: [String]) throws {
        try fixture.database.pool.write { db in
            for title in titles {
                try db.execute(sql: """
                    INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
                    VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
                    """, arguments: [UUID().uuidString, title])
            }
        }
    }

    private func titles(_ database: StorageDatabase) throws -> [String] { try database.pool.read { try String.fetchAll($0, sql: "SELECT title FROM items ORDER BY title") } }

    /// Every file of the library (not the restore bookkeeping) with its size and hash, for before-and-after comparison.
    private func tree(_ paths: AppPaths) -> [String] {
        var lines: [String] = []
        let base = paths.root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            if relative.hasPrefix("restore-pending") || relative.hasPrefix("safety-copies") || relative.hasPrefix("restore-result") { continue }
            lines.append("\(relative) \((try? LibraryBackup.sha256(of: url)) ?? "?")")
        }
        return lines.sorted()
    }

    private func reopen(_ paths: AppPaths) throws -> StorageDatabase {
        try paths.prepare()
        guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw CocoaError(.fileReadUnknown) }
        return database
    }

    // MARK: Validation

    @Test func aFolderThatIsNotABackupIsRefused() throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let empty = r.fixture.temp.url.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: BackupError.notABackup) { try r.restore.validate(empty) }
        #expect(throws: BackupError.notABackup) { try r.restore.validate(r.fixture.temp.url.appendingPathComponent("missing")) }
    }

    @Test func aDamagedOrChangedFileIsRefusedByItsChecksum() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let package = try await r.backup.make(into: r.folder, includePictures: true, now: when).package
        let evidence = package.appendingPathComponent("evidence/e1.png")
        try Data("changed".utf8).write(to: evidence)
        #expect(throws: BackupError.damaged("evidence/e1.png")) { try r.restore.validate(package) }
        try Data("cut-out one".utf8).write(to: evidence)
        #expect((try? r.restore.validate(package)) != nil)
        // A flipped byte in the database.
        let database = package.appendingPathComponent("memorri.sqlite")
        var bytes = try Data(contentsOf: database); bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: database)
        #expect(throws: BackupError.damaged("memorri.sqlite")) { try r.restore.validate(package) }
    }

    @Test func aBackupFromANewerVersionOrFormatIsRefused() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let package = try await r.backup.make(into: r.folder, includePictures: false, now: when).package
        let manifestURL = package.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        func edit(_ change: (inout [String: Any]) -> Void) throws {
            var object = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            change(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        }
        try edit { $0["schema"] = "v999" }
        #expect(throws: BackupError.newerVersion) { try r.restore.validate(package) }
        try edit { $0["format"] = 2 }
        #expect(throws: BackupError.newerVersion) { try r.restore.validate(package) }
        try edit { $0["files"] = [["path": "../outside.txt", "size": 1, "sha256": "x"], ["path": "memorri.sqlite", "size": 1, "sha256": "x"]] }
        #expect(throws: BackupError.notABackup) { try r.restore.validate(package) }
    }

    // MARK: The swap

    @Test func aStagedRestoreIsFinishedAtTheNextStartWithASafetyCopyOfTheReplacedLibrary() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let package = try await r.backup.make(into: r.folder, includePictures: true, now: when).package
        // The library moves on after the backup.
        try addItems(r.fixture, ["Added later"])
        try Data("later cut-out".utf8).write(to: r.paths.evidence.appendingPathComponent("e2.png"))
        try FileManager.default.removeItem(at: r.paths.evidence.appendingPathComponent("e1.png"))
        try r.restore.stage(package)
        #expect(r.restore.staged?.includesPictures == true)
        try r.fixture.database.pool.close()                                    // the app is restarting

        let result = try #require(StorageBootstrap.finishStagedRestore(paths: r.paths, now: when))
        #expect(result.outcome == .restored && result.includesPictures == true && result.backupCreated == when)
        let database = try reopen(r.paths)
        #expect(try titles(database) == ["Budget review", "Standup"])
        #expect(FileManager.default.fileExists(atPath: r.paths.evidence.appendingPathComponent("e1.png").path) && !FileManager.default.fileExists(atPath: r.paths.evidence.appendingPathComponent("e2.png").path))
        #expect(!FileManager.default.fileExists(atPath: r.paths.restorePending.path))
        // The replaced library is in the safety copy, whole.
        let copies = SafetyCopies(paths: r.paths).list()
        #expect(copies.count == 1 && copies[0].name == result.safetyCopy && copies[0].size > 0)
        let kept = r.paths.safetyCopies.appendingPathComponent(copies[0].name)
        let old = try DatabaseQueue(path: kept.appendingPathComponent("memorri.sqlite").path)
        let oldTitles = try await old.read { try String.fetchAll($0, sql: "SELECT title FROM items ORDER BY title") }
        #expect(oldTitles == ["Added later", "Budget review", "Standup"])
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("evidence/e2.png").path))
        // The note is read once.
        #expect(StorageBootstrap.takeRestoreResult(paths: r.paths)?.outcome == .restored && StorageBootstrap.takeRestoreResult(paths: r.paths) == nil)
        // Deleting the safety copy frees its space.
        try SafetyCopies(paths: r.paths).delete(copies[0].name)
        #expect(SafetyCopies(paths: r.paths).list().isEmpty)
    }

    @Test func aBackupWithoutPicturesRestoresTheItemsAndLeavesTheCapturesWithoutPictures() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let picture = r.paths.root.appendingPathComponent(r.fixture.image.fullPath)
        #expect(FileManager.default.fileExists(atPath: picture.path))
        let package = try await r.backup.make(into: r.folder, includePictures: false, now: when).package
        try r.restore.stage(package)
        try r.fixture.database.pool.close()
        let result = try #require(StorageBootstrap.finishStagedRestore(paths: r.paths, now: when))
        #expect(result.outcome == .restored && result.includesPictures == false)
        let database = try reopen(r.paths)
        #expect(try titles(database) == ["Budget review", "Standup"])
        #expect(!FileManager.default.fileExists(atPath: picture.path))                      // the picture went with the replaced library
        let kept = r.paths.safetyCopies.appendingPathComponent(try #require(result.safetyCopy))
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent(r.fixture.image.fullPath).path))
        let rows = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_images") }
        #expect(rows == 1)                                                                   // the capture is still listed; its picture is missing
    }

    @Test func aFailureAtAnyStepLeavesTheLibraryExactlyAsItWas() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        let package = try await r.backup.make(into: r.folder, includePictures: true, now: when).package
        try addItems(r.fixture, ["Added later"])
        try r.fixture.database.pool.close()
        let before = tree(r.paths)
        #expect(before.contains { $0.hasPrefix("memorri.sqlite ") } && before.contains { $0.hasPrefix("evidence/") } && before.contains { $0.hasPrefix("captures/") })
        for limit in 0..<6 {
            try r.restore.stage(package)
            let result = try #require(StorageBootstrap.finishStagedRestore(paths: r.paths, now: when, failAfterMoves: limit))
            #expect(result.outcome == .failed && result.safetyCopy == nil, "failing after \(limit) moves")
            #expect(tree(r.paths) == before, "the library after failing at move \(limit)")
            #expect(!FileManager.default.fileExists(atPath: r.paths.restorePending.path) && SafetyCopies(paths: r.paths).list().isEmpty)
        }
        let database = try reopen(r.paths)
        #expect(try titles(database) == ["Added later", "Budget review", "Standup"])
    }

    @Test func aStagedRestoreCanBeCancelledAndAnIncompleteOneIsDropped() async throws {
        let r = try rig(); defer { r.fixture.cleanUp() }
        #expect(StorageBootstrap.finishStagedRestore(paths: r.paths, now: when) == nil)         // nothing staged
        let package = try await r.backup.make(into: r.folder, includePictures: false, now: when).package
        try r.restore.stage(package)
        try r.restore.cancelStaged()
        #expect(r.restore.staged == nil && StorageBootstrap.finishStagedRestore(paths: r.paths, now: when) == nil)
        try FileManager.default.createDirectory(at: r.paths.restorePending, withIntermediateDirectories: true)   // an empty staging folder
        try r.fixture.database.pool.close()
        let before = tree(r.paths)
        let result = try #require(StorageBootstrap.finishStagedRestore(paths: r.paths, now: when))
        #expect(result.outcome == .failed && tree(r.paths) == before && !FileManager.default.fileExists(atPath: r.paths.restorePending.path))
    }

    // MARK: Sync after a restore (FR-020)

    @Test func afterARestoreTheFirstSyncWaitsForAPreviewAgain() {
        let settings = FakeSettingsStore()
        settings.setBool(true, forKey: SyncStore.confirmedKey)
        SyncStore.holdFirstSync(in: settings)
        #expect(settings.bool(forKey: SyncStore.confirmedKey, default: true) == false)
    }
}
