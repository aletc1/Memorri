import Foundation

/// A library that a restore replaced, kept until the user deletes it (spec 010 FR-021).
public struct SafetyCopy: Identifiable, Equatable, Sendable {
    public let name: String
    public let created: Date
    public let size: Int64
    public var id: String { name }
}

public struct SafetyCopies: Sendable {
    let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func list() -> [SafetyCopy] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: paths.safetyCopies, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url -> SafetyCopy? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { return nil }
            return SafetyCopy(name: url.lastPathComponent, created: values?.creationDate ?? .distantPast, size: StorageStats.bytes(under: url))
        }
        .sorted { $0.created > $1.created }
    }

    public func delete(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return }
        let url = paths.safetyCopies.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
