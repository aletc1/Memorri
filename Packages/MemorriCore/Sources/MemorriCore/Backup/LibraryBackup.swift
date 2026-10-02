import CryptoKit
import Foundation
import GRDB

/// What a backup holds, written last so a package without it is never taken for a finished one.
public struct BackupManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }
    public static let format = 1
    public static let fileName = "manifest.json"
    public static let databaseName = "memorri.sqlite"

    public let format: Int
    /// The newest migration the database had (a newer app version has a later one).
    public let schema: String
    public let app: String
    public let created: Date
    public let includesPictures: Bool
    public let files: [File]
}

public enum BackupError: Error, Equatable, Sendable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case cancelled
    case notABackup
    case damaged(String)
    case newerVersion
    case failed(String)

    /// In words for the user.
    public var message: String {
        switch self {
        case .notEnoughSpace(let needed, let available):
            "There is not enough free space: the backup needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
        case .cancelled: "The backup was cancelled. Nothing was written."
        case .notABackup: "This is not a Memorri backup."
        case .damaged(let file): "The backup is damaged (\(file) does not match). Nothing was changed."
        case .newerVersion: "This backup was made by a newer version of Memorri. Update the app first. Nothing was changed."
        case .failed(let why): why
        }
    }
}

/// Makes a backup of the library: a package folder with a consistent snapshot of the database, the cut-outs and, when asked, the capture pictures
/// (spec 010 FR-017, FR-018; ADR 0027). It writes into a hidden folder and renames it when it is whole, so a cancelled or failed backup leaves nothing.
public struct LibraryBackup: Sendable {
    public struct Sizes: Sendable, Equatable {
        public let withPictures: Int64
        public let withoutPictures: Int64
    }

    let database: StorageDatabase
    let paths: AppPaths
    let appVersion: String
    let availableSpace: @Sendable (URL) -> Int64?

    public init(database: StorageDatabase, paths: AppPaths, appVersion: String = "0",
                availableSpace: @escaping @Sendable (URL) -> Int64? = LibraryBackup.volumeSpace) {
        self.database = database; self.paths = paths; self.appVersion = appVersion; self.availableSpace = availableSpace
    }

    public static let volumeSpace: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// The size of the backup with and without the capture pictures, before anything is written.
    public func sizes() -> Sizes {
        let base = ["", "-wal"].reduce(Int64(0)) { $0 + Self.size(ofFileAt: paths.database.path + $1) } + StorageStats.bytes(under: paths.evidence)
        return Sizes(withPictures: base + StorageStats.bytes(under: paths.captures), withoutPictures: base)
    }

    /// Returns the package and its manifest. Progress goes from 0 to 1. Cancelling the task throws `BackupError.cancelled`.
    public func make(into folder: URL, includePictures: Bool, now: Date = Date(), progress: @Sendable (Double) -> Void = { _ in }) async throws -> (package: URL, manifest: BackupManifest) {
        let sizes = sizes()
        let needed = includePictures ? sizes.withPictures : sizes.withoutPictures
        if let free = availableSpace(folder), free < Int64(Double(needed) * 1.05) + 1_000_000 { throw BackupError.notEnoughSpace(needed: needed, available: free) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        var name = "Memorri Backup \(formatter.string(from: now))"
        var number = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".memorribackup").path) { number += 1; name = "Memorri Backup \(formatter.string(from: now)) \(number)" }
        let final = folder.appendingPathComponent(name + ".memorribackup", isDirectory: true)
        let partial = folder.appendingPathComponent(".\(name).partial", isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: partial, withIntermediateDirectories: true)
            try Task.checkCancellation()
            // The snapshot is taken in one read transaction, so it is consistent as of one moment however busy the app is.
            let snapshot = try DatabaseQueue(path: partial.appendingPathComponent(BackupManifest.databaseName).path)
            try database.pool.backup(to: snapshot)
            // The copy keeps the library's write-ahead mode in its header; a backup is one self-contained file that opens read-only anywhere.
            try await snapshot.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try snapshot.close()
            let migrator = Migrations.make()
            let applied = try await database.pool.read { try migrator.appliedIdentifiers($0) }
            let schema = migrator.migrations.last(where: applied.contains) ?? ""

            let sources = Self.listFiles(paths: paths, includePictures: includePictures)
            var files: [BackupManifest.File] = []
            let total = Double(max(1, sources.count + 1))
            files.append(try Self.describe(partial, BackupManifest.databaseName))
            progress(1 / total)
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let target = partial.appendingPathComponent(source.to)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source.from, to: target)
                files.append(try Self.describe(partial, source.to))
                progress(Double(index + 2) / total)
            }
            try Task.checkCancellation()
            let manifest = BackupManifest(format: BackupManifest.format, schema: schema, app: appVersion, created: now, includesPictures: includePictures, files: files)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: partial.appendingPathComponent(BackupManifest.fileName), options: .atomic)
            try manager.moveItem(at: partial, to: final)
            progress(1)
            return (final, manifest)
        } catch {
            try? manager.removeItem(at: partial)
            if error is CancellationError { throw BackupError.cancelled }
            throw (error as? BackupError) ?? BackupError.failed("The backup could not be written: \(error.localizedDescription)")
        }
    }

    // MARK: Files

    /// Every file of the evidence folder (and of the captures folder when pictures are included) with its path inside the package.
    static func listFiles(paths: AppPaths, includePictures: Bool) -> [(from: URL, to: String)] {
        var sources: [(from: URL, to: String)] = []
        for (directory, label) in [(paths.evidence, "evidence")] + (includePictures ? [(paths.captures, "captures")] : []) {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let base = directory.resolvingSymlinksInPath().path          // the enumerator may return the real path of a symlinked folder
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                sources.append((url, "\(label)/\(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))"))
            }
        }
        return sources
    }

    static func describe(_ root: URL, _ relative: String) throws -> BackupManifest.File {
        let url = root.appendingPathComponent(relative)
        return BackupManifest.File(path: relative, size: size(ofFileAt: url.path), sha256: try sha256(of: url))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func size(ofFileAt path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
