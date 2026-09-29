import Foundation
import Testing

/// FR-017: the app must not send any data over the network. This is a source scan, a first line
/// of defence; the runtime check (`lsof`) is in quickstart.md.
@Suite struct NoNetworkTests {
    static let forbidden = ["URLSession", "NWConnection", "import Network", "CFNetwork"]

    /// Returns "path: pattern" for every forbidden pattern found in Swift files under `directory`.
    static func violations(in directory: URL) -> [String] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for pattern in forbidden where text.contains(pattern) {
                found.append("\(file.lastPathComponent): \(pattern)")
            }
        }
        return found
    }

    /// Repository root, from this file's location (Packages/MemorriCore/Tests/MemorriCoreTests).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func scannerFindsAPlantedViolation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "import Foundation\nlet s = URLSession.shared\n".write(
            to: dir.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
        #expect(Self.violations(in: dir) == ["Bad.swift: URLSession"])
    }

    @Test func coreSourcesUseNoNetworking() {
        let dir = Self.root.appendingPathComponent("Packages/MemorriCore/Sources")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(Self.violations(in: dir).isEmpty)
    }

    @Test func appSourcesUseNoNetworking() {
        let dir = Self.root.appendingPathComponent("App")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(Self.violations(in: dir).isEmpty)
    }

    @Test func projectDeclaresNoNetworkEntitlement() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(!text.contains("com.apple.security.network"))
    }
}
