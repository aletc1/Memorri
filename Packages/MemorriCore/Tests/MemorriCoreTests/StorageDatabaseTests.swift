import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct StorageDatabaseTests {
    private func makePaths(_ temp: TempDirectory) throws -> AppPaths {
        let paths = AppPaths(root: temp.url.appendingPathComponent("Memorri"))
        try paths.prepare()
        return paths
    }

    private func opened(_ result: StorageDatabase.OpenResult) -> StorageDatabase? {
        if case .opened(let db) = result { return db }
        return nil
    }

    @Test func schemaMatchesTheDataModel() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            let events = try db.columns(in: "capture_events").map(\.name)
            #expect(events == ["id", "captured_at", "trigger", "status", "failure_reason", "display_count"])
            let images = try db.columns(in: "capture_images").map(\.name)
            #expect(images == ["id", "event_id", "display_id", "display_name", "pixel_width", "pixel_height",
                               "scale", "full_path", "model_path", "model_width", "model_height",
                               "full_bytes", "model_bytes", "missing"])
            let notNull = Dictionary(uniqueKeysWithValues: try db.columns(in: "capture_events").map { ($0.name, $0.isNotNull) })
            #expect(notNull["failure_reason"] == false)
            #expect(notNull["status"] == true)
            let indexes = try db.indexes(on: "capture_events").flatMap(\.columns) + db.indexes(on: "capture_images").flatMap(\.columns)
            #expect(indexes.contains("captured_at") && indexes.contains("event_id"))
        }
    }

    @Test func triggerAndStatusAreConstrained() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        let store = CaptureStore(database: db)
        #expect(throws: (any Error).self) { try store.insert(event: makeEventRecord(trigger: "swipe"), images: []) }
        #expect(throws: (any Error).self) { try store.insert(event: makeEventRecord(status: "done"), images: []) }
        try store.insert(event: makeEventRecord(trigger: "menu", status: "partial"), images: [])
        #expect(try store.count() == 1)
    }

    @Test func deletingAnEventCascadesToItsImages() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        let store = CaptureStore(database: db)
        let event = makeEventRecord()
        try store.insert(event: event, images: [makeImageRecord(eventID: event.id), makeImageRecord(eventID: event.id)])
        #expect(try store.allImages().count == 2)
        try store.deleteEvents(ids: [event.id])
        #expect(try store.allImages().isEmpty)
    }

    @Test func openingTwiceIsIdempotentAndKeepsData() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let db = try #require(opened(try StorageDatabase.open(paths: paths)))
            try CaptureStore(database: db).insert(event: makeEventRecord(), images: [])
        }
        let again = try #require(opened(try StorageDatabase.open(paths: paths)))
        #expect(try CaptureStore(database: again).count() == 1)
    }

    @Test func aDatabaseFromANewerVersionIsRefusedAndLeftUntouched() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            var migrator = Migrations.make()
            migrator.registerMigration("v99") { db in try db.execute(sql: "CREATE TABLE from_the_future (x TEXT)") }
            try migrator.migrate(pool)
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let before = try Data(contentsOf: paths.database)
        let result = try StorageDatabase.open(paths: paths)
        guard case .refusedNewerVersion = result else { Issue.record("expected refusedNewerVersion"); return }
        let after = try Data(contentsOf: paths.database)
        #expect(try Data(contentsOf: paths.database) == before)
    }

    @Test func aDamagedFileIsSetAsideNotDeleted() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        let garbage = Data("this is not a database, just text that is long enough to look like a file".utf8)
        try garbage.write(to: paths.database)
        let result = try StorageDatabase.open(paths: paths)
        guard case .openedAfterSettingAside(let db, let damaged) = result else {
            Issue.record("expected openedAfterSettingAside"); return
        }
        #expect(damaged.lastPathComponent.hasPrefix("memorri.sqlite.damaged-"))
        #expect(try Data(contentsOf: damaged) == garbage)
        #expect(damaged.deletingLastPathComponent().path == paths.root.path)
        try CaptureStore(database: db).insert(event: makeEventRecord(), images: [])
        #expect(try CaptureStore(database: db).count() == 1)
    }
}
