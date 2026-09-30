import Foundation
import Testing

/// Captured content must not leave the Mac (constitution I). This is a source scan, a first line of
/// defence; the runtime check (`lsof`) is in the quickstarts. Since spec 003 exactly one file may use
/// `URLSession`: the loopback-only transport (ADR 0011). Everything else stays forbidden.
@Suite struct NoNetworkTests {
    static let forbidden = ["URLSession", "NWConnection", "import Network", "CFNetwork"]
    /// The only file allowed to contain `URLSession`.
    static let urlSessionAllowList: Set<String> = ["OllamaURLSessionTransport.swift"]

    /// Returns "path: pattern" for every forbidden pattern found in Swift files under `directory`.
    static func violations(in directory: URL, allowURLSessionIn allowed: Set<String> = urlSessionAllowList) -> [String] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for pattern in forbidden where text.contains(pattern) {
                if pattern == "URLSession", allowed.contains(file.lastPathComponent) { continue }
                found.append("\(file.lastPathComponent): \(pattern)")
            }
        }
        return found
    }

    /// Names of the Swift files under `directory` that contain `URLSession`.
    static func filesUsingURLSession(in directory: URL) -> [String] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && ((try? String(contentsOf: $0, encoding: .utf8))?.contains("URLSession") ?? false) }
            .map(\.lastPathComponent)
    }

    /// Repository root, from this file's location (Packages/MemorriCore/Tests/MemorriCoreTests).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plant(_ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "import Foundation\nlet s = URLSession.shared\n".write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func scannerFindsAPlantedViolation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try plant("Bad.swift", in: dir)
        #expect(Self.violations(in: dir) == ["Bad.swift: URLSession"])
    }

    @Test func scannerStillFindsURLSessionInAnyOtherFileAndAllowsTheOneName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try plant("OllamaURLSessionTransport.swift", in: dir)
        try plant("SomethingElse.swift", in: dir)
        #expect(Self.violations(in: dir) == ["SomethingElse.swift: URLSession"])
    }

    @Test func otherNetworkingIsForbiddenEvenInTheAllowedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "import Network\nlet c: NWConnection? = nil\n".write(
            to: dir.appendingPathComponent("OllamaURLSessionTransport.swift"), atomically: true, encoding: .utf8)
        #expect(Set(Self.violations(in: dir)) == ["OllamaURLSessionTransport.swift: NWConnection",
                                                   "OllamaURLSessionTransport.swift: import Network"])
    }

    @Test func theAllowListHasExactlyOneEntry() {
        #expect(Self.urlSessionAllowList == ["OllamaURLSessionTransport.swift"])
    }

    @Test func coreSourcesUseNoNetworkingExceptTheLoopbackTransport() {
        let dir = Self.root.appendingPathComponent("Packages/MemorriCore/Sources")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(Self.violations(in: dir).isEmpty)
        #expect(Self.filesUsingURLSession(in: dir) == ["OllamaURLSessionTransport.swift"])
    }

    @Test func appSourcesUseNoNetworking() {
        let dir = Self.root.appendingPathComponent("App")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(Self.violations(in: dir, allowURLSessionIn: []).isEmpty)
    }

    @Test func theAllowedFileChecksTheLoopbackRule() throws {
        let file = Self.root.appendingPathComponent("Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaURLSessionTransport.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("LoopbackAddress"))
        #expect(text.contains("isSameServer(as"))
    }

    @Test func projectDeclaresNoNetworkEntitlement() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(!text.contains("com.apple.security.network"))
    }
}
