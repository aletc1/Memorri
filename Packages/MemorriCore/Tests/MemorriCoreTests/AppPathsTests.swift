import Foundation
import Testing
@testable import MemorriCore

@Suite struct AppPathsTests {
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func prepareCreatesTheFoldersPrivately() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        for url in [paths.root, paths.captures, paths.staging, paths.evidence] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            #expect(try mode(url) == 0o700)
        }
    }

    @Test func prepareIsIdempotentAndRecreatesADeletedFolder() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        try paths.prepare()
        try FileManager.default.removeItem(at: paths.root)
        try paths.prepare()
        #expect(FileManager.default.fileExists(atPath: paths.staging.path))
    }

    @Test func rootIsExcludedFromBackups() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        let values = try paths.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func databaseLivesInTheRoot() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x/Memorri"))
        #expect(paths.database.path == "/tmp/x/Memorri/memorri.sqlite")
        #expect(paths.captures.path == "/tmp/x/Memorri/captures")
        #expect(paths.staging.path == "/tmp/x/Memorri/staging")
        #expect(paths.evidence.path == "/tmp/x/Memorri/evidence")
    }
}
