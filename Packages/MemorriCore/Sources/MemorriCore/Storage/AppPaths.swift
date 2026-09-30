import Foundation

/// Where Memorri keeps its records and pictures (FR-012).
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Memorri`.
    public static func standard() throws -> AppPaths {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return AppPaths(root: support.appendingPathComponent("Memorri", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("memorri.sqlite") }
    public var captures: URL { root.appendingPathComponent("captures", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// Creates the folders (mode 0700) and excludes the root from backups. Safe to call again.
    public func prepare() throws {
        let manager = FileManager.default
        for url in [root, captures, staging] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
