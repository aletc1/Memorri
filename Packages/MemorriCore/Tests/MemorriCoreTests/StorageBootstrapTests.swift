import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct StorageBootstrapTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func paths(_ temp: TempDirectory) -> AppPaths {
        AppPaths(root: temp.url.appendingPathComponent("Memorri"))
    }

    private func write(_ paths: AppPaths, _ relative: String) throws {
        let url = paths.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func theFirstStartCreatesTheFolderAndAnEmptyDatabase() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = paths(temp)
        let context = try StorageBootstrap.start(paths: paths)
        #expect(FileManager.default.fileExists(atPath: paths.root.path))
        #expect(try context.store?.count() == 0)
        #expect(context.notice == nil && context.capturingDisabledReason == nil)
    }

    @Test func capturesSurviveARestart() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = paths(temp)
        for round in 0..<3 {
            let context = try StorageBootstrap.start(paths: paths)
            #expect(try context.store?.count() == round)
            let event = makeEventRecord(id: "event-\(round)", at: capturedAt.addingTimeInterval(Double(round)))
            let image = makeImageRecord(eventID: event.id, id: "img-\(round)")
            try write(paths, image.fullPath)
            try write(paths, image.modelPath)
            try context.store?.insert(event: event, images: [image])
        }
        let again = try StorageBootstrap.start(paths: paths)
        #expect(try again.store?.count() == 3)
        #expect(try again.store?.allImages().allSatisfy { !$0.missing } == true)
    }

    @Test func leftoversAreSweptAtStart() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = paths(temp)
        let first = try StorageBootstrap.start(paths: paths)
        let event = makeEventRecord(id: "event-1", at: capturedAt)
        let image = makeImageRecord(eventID: event.id, id: "img")
        try write(paths, image.fullPath)                              // model picture deleted by hand
        try first.store?.insert(event: event, images: [image])
        try FileManager.default.createDirectory(at: paths.staging.appendingPathComponent("half-written"), withIntermediateDirectories: true)
        try write(paths, "captures/2027-01/no-record/a-full.heic")

        let context = try StorageBootstrap.start(paths: paths)
        #expect(context.reconcile == ReconcileReport(stagingRemoved: 1, orphansRemoved: 1, markedMissing: 1))
        #expect(try context.store?.allImages().first?.missing == true)
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("captures/2027-01/no-record").path))
    }

    @Test func aDamagedDatabaseIsSetAsideAndACleanOneIsUsed() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = paths(temp)
        try paths.prepare()
        try Data("not a database, only some text that is long enough".utf8).write(to: paths.database)
        let context = try StorageBootstrap.start(paths: paths)
        guard case .damagedDatabaseSetAside(let name)? = context.notice else { Issue.record("expected a notice"); return }
        #expect(name.hasPrefix("memorri.sqlite.damaged-"))
        #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(name).path))
        #expect(try context.store?.count() == 0)
        #expect(context.capturingDisabledReason == nil)
    }

    @Test func aDatabaseFromANewerVersionDisablesCapturingAndIsLeftUntouched() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = paths(temp)
        try paths.prepare()
        do {
            let pool = try DatabasePool(path: paths.database.path)
            var migrator = Migrations.make()
            migrator.registerMigration("v99") { db in try db.execute(sql: "CREATE TABLE from_the_future (x TEXT)") }
            try migrator.migrate(pool)
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let before = try Data(contentsOf: paths.database)
        let context = try StorageBootstrap.start(paths: paths)
        #expect(context.store == nil)
        #expect(context.capturingDisabledReason == "database from a newer version")
        #expect(try Data(contentsOf: paths.database) == before)
    }
}
