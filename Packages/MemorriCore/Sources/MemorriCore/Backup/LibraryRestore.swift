import Foundation
import GRDB
import os

/// What a finished (or failed) restore did, read once by the app after start (`restore-result.json`).
public struct RestoreResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case restored, failed }
    public let outcome: Outcome
    public let backupCreated: Date?
    public let includesPictures: Bool?
    /// The folder name under `safety-copies/` that holds the replaced library.
    public let safetyCopy: String?
    public let reason: String?
    public let finishedAt: Date
}

/// Checks a backup and stages it for the next start (spec 010 FR-019; ADR 0027). Nothing here touches the live library.
public struct LibraryRestore: Sendable {
    let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    /// The manifest of a restore waiting for the next start, if any.
    public var staged: BackupManifest? { try? Self.readManifest(paths.restorePending) }

    /// Reads the manifest and checks every file against it, that the database is whole and that it is not from a newer version.
    @discardableResult
    public func validate(_ package: URL) throws -> BackupManifest {
        let manifest = try Self.readManifest(package)
        if manifest.format > BackupManifest.format { throw BackupError.newerVersion }
        guard manifest.format == BackupManifest.format else { throw BackupError.notABackup }
        let migrator = Migrations.make()
        guard migrator.migrations.contains(manifest.schema) else { throw BackupError.newerVersion }
        guard manifest.files.contains(where: { $0.path == BackupManifest.databaseName }) else { throw BackupError.notABackup }
        for file in manifest.files {
            guard !file.path.hasPrefix("/"), !file.path.contains("..") else { throw BackupError.notABackup }
            let url = package.appendingPathComponent(file.path)
            guard LibraryBackup.size(ofFileAt: url.path) == file.size, (try? LibraryBackup.sha256(of: url)) == file.sha256 else { throw BackupError.damaged(file.path) }
        }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: package.appendingPathComponent(BackupManifest.databaseName).path, configuration: configuration)
            let ok = try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") } == "ok"
            let superseded = try queue.read { try migrator.hasBeenSuperseded($0) }
            if superseded { throw BackupError.newerVersion }
            if !ok { throw BackupError.damaged(BackupManifest.databaseName) }
        } catch let error as BackupError { throw error } catch { throw BackupError.damaged(BackupManifest.databaseName) }
        return manifest
    }

    /// Validates the package and copies it next to the library as `restore-pending`; the swap happens at the next start. Replaces an earlier staged restore.
    @discardableResult
    public func stage(_ package: URL) throws -> BackupManifest {
        let manifest = try validate(package)
        let manager = FileManager.default
        let partial = paths.root.appendingPathComponent("restore-pending.partial", isDirectory: true)
        try? manager.removeItem(at: partial)
        do {
            try manager.createDirectory(at: partial, withIntermediateDirectories: true)
            for file in manifest.files {
                let target = partial.appendingPathComponent(file.path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: package.appendingPathComponent(file.path), to: target)
            }
            try manager.copyItem(at: package.appendingPathComponent(BackupManifest.fileName), to: partial.appendingPathComponent(BackupManifest.fileName))
            try? manager.removeItem(at: paths.restorePending)
            try manager.moveItem(at: partial, to: paths.restorePending)
        } catch {
            try? manager.removeItem(at: partial)
            throw BackupError.failed("The backup could not be prepared: \(error.localizedDescription)")
        }
        return manifest
    }

    /// Forgets a staged restore before the app restarts.
    public func cancelStaged() throws {
        if FileManager.default.fileExists(atPath: paths.restorePending.path) { try FileManager.default.removeItem(at: paths.restorePending) }
    }

    static func readManifest(_ package: URL) throws -> BackupManifest {
        guard let data = try? Data(contentsOf: package.appendingPathComponent(BackupManifest.fileName)) else { throw BackupError.notABackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BackupManifest.self, from: data) else { throw BackupError.notABackup }
        return manifest
    }
}

extension StorageBootstrap {
    private static let restoreLogger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    /// Finishes a staged restore before the database is opened: the current database, evidence and captures move into `safety-copies/<time>/`, the
    /// staged files take their place, and any failure moves everything back (ADR 0027). Returns nil when nothing was staged. `failAfterMoves` is a
    /// test seam that fails the swap after that many moves.
    @discardableResult
    public static func finishStagedRestore(paths: AppPaths, now: Date = Date(), failAfterMoves: Int? = nil) -> RestoreResult? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.restorePending.path) else { return nil }
        func finish(_ result: RestoreResult) -> RestoreResult {
            try? manager.removeItem(at: paths.restorePending)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(result).write(to: paths.restoreResult, options: .atomic)
            return result
        }
        guard let manifest = try? LibraryRestore.readManifest(paths.restorePending),
              manager.fileExists(atPath: paths.restorePending.appendingPathComponent(BackupManifest.databaseName).path) else {
            return finish(RestoreResult(outcome: .failed, backupCreated: nil, includesPictures: nil, safetyCopy: nil, reason: "the staged backup is incomplete", finishedAt: now))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = formatter.string(from: now)
        var number = 1
        while manager.fileExists(atPath: paths.safetyCopies.appendingPathComponent(name).path) { number += 1; name = formatter.string(from: now) + "-\(number)" }
        let safety = paths.safetyCopies.appendingPathComponent(name, isDirectory: true)

        var done: [(from: URL, to: URL)] = []
        func move(_ from: URL, _ to: URL) throws {
            if let limit = failAfterMoves, done.count >= limit { throw CocoaError(.fileWriteUnknown) }
            try manager.moveItem(at: from, to: to)
            done.append((from, to))
        }
        do {
            try manager.createDirectory(at: safety, withIntermediateDirectories: true)
            for item in ["memorri.sqlite", "memorri.sqlite-wal", "memorri.sqlite-shm", "evidence", "captures"] {
                let from = paths.root.appendingPathComponent(item)
                if manager.fileExists(atPath: from.path) { try move(from, safety.appendingPathComponent(item)) }
            }
            for item in ["memorri.sqlite", "evidence", "captures"] {
                let staged = paths.restorePending.appendingPathComponent(item)
                if manager.fileExists(atPath: staged.path) { try move(staged, paths.root.appendingPathComponent(item)) }
            }
            restoreLogger.notice("restore finished, safety copy \(name, privacy: .public)")
            return finish(RestoreResult(outcome: .restored, backupCreated: manifest.created, includesPictures: manifest.includesPictures, safetyCopy: name, reason: nil, finishedAt: now))
        } catch {
            // Put everything back, newest move first, and leave the library as it was.
            for step in done.reversed() { try? manager.moveItem(at: step.to, to: step.from) }
            try? manager.removeItem(at: safety)
            restoreLogger.error("restore failed and was rolled back")
            return finish(RestoreResult(outcome: .failed, backupCreated: manifest.created, includesPictures: manifest.includesPictures, safetyCopy: nil,
                                        reason: "the files could not be swapped; the library was left as it was", finishedAt: now))
        }
    }

    /// What the last restore did, once: reading it removes the note.
    public static func takeRestoreResult(paths: AppPaths) -> RestoreResult? {
        guard let data = try? Data(contentsOf: paths.restoreResult) else { return nil }
        try? FileManager.default.removeItem(at: paths.restoreResult)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RestoreResult.self, from: data)
    }
}
