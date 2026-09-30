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

    // MARK: migration "v2" (spec 003)

    private func column(_ table: String, _ name: String, in db: Database) throws -> ColumnInfo {
        try #require(try db.columns(in: table).first { $0.name == name })
    }

    @Test func v2CreatesTheAnalysisTables() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            #expect(try db.columns(in: "analysis_jobs").map(\.name) ==
                    ["id", "kind", "image_id", "state", "attempts", "not_before", "failure_reason", "created_at", "updated_at"])
            #expect(try db.columns(in: "model_runs").map(\.name) ==
                    ["id", "job_id", "image_id", "attempt", "model", "think", "temperature", "image_long_edge",
                     "prompt_version", "schema_version", "started_at", "duration_ms", "outcome", "failure_reason",
                     "request_json", "raw_answer"])
            func notNull(_ table: String, _ name: String) throws -> Bool { try self.column(table, name, in: db).isNotNull }
            for name in ["kind", "state", "attempts", "created_at", "updated_at"] {
                let flag = try notNull("analysis_jobs", name); #expect(flag, "\(name) should be NOT NULL")
            }
            for name in ["image_id", "not_before", "failure_reason"] {
                let flag = try notNull("analysis_jobs", name); #expect(!flag, "\(name) should be nullable")
            }
            for name in ["job_id", "attempt", "model", "think", "temperature", "image_long_edge", "prompt_version",
                         "schema_version", "started_at", "duration_ms", "outcome", "request_json"] {
                let flag = try notNull("model_runs", name); #expect(flag, "\(name) should be NOT NULL")
            }
            for name in ["image_id", "failure_reason", "raw_answer"] {
                let flag = try notNull("model_runs", name); #expect(!flag, "\(name) should be nullable")
            }
            #expect(try db.columns(in: "analysis_jobs").first { $0.name == "attempts" }?.defaultValueSQL == "0")
            #expect(try db.foreignKeys(on: "analysis_jobs").isEmpty)
            let runKeys = try db.foreignKeys(on: "model_runs")
            #expect(runKeys.count == 1 && runKeys[0].destinationTable == "capture_images")
            #expect(runKeys[0].originColumns == ["image_id"])
            let jobIndexes = try db.indexes(on: "analysis_jobs").map(\.columns)
            #expect(jobIndexes.contains(["state", "created_at"]))
            let runIndexes = try db.indexes(on: "model_runs").map(\.columns)
            #expect(runIndexes.contains(["image_id"]) && runIndexes.contains(["job_id"]))
        }
    }

    private func insertJob(_ db: Database, id: String, kind: String = "test", state: String = "waiting", image: String? = nil) throws {
        try db.execute(sql: "INSERT INTO analysis_jobs (id, kind, image_id, state, created_at, updated_at) VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))",
                       arguments: [id, kind, image, state])
    }

    private func insertRun(_ db: Database, id: String, job: String, image: String?, outcome: String = "success") throws {
        try db.execute(sql: """
            INSERT INTO model_runs (id, job_id, image_id, attempt, model, think, temperature, image_long_edge, prompt_version,
                                    schema_version, started_at, duration_ms, outcome, request_json)
            VALUES (?, ?, ?, 1, 'm', 'off', 0, 2048, 'test-v1', 'test-v1', datetime('now'), 10, ?, '{}')
            """, arguments: [id, job, image, outcome])
    }

    @Test func v2ConstraintsRejectBadValuesButAnyKindIsStored() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            #expect(throws: (any Error).self) { try self.insertJob(db, id: "j1", state: "done") }
            try self.insertJob(db, id: "j2", kind: "extract")                       // no CHECK on kind
            #expect(throws: (any Error).self) { try self.insertRun(db, id: "r1", job: "j2", image: nil, outcome: "ok") }
            try self.insertRun(db, id: "r2", job: "j2", image: nil)
            #expect(try Int.fetchOne(db, sql: "SELECT attempts FROM analysis_jobs WHERE id = 'j2'") == 0)
        }
    }

    @Test func deletingACaptureDeletesItsRunsButNotJobsOrImagelessRuns() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        let store = CaptureStore(database: db)
        let event = makeEventRecord()
        let image = makeImageRecord(eventID: event.id)
        try store.insert(event: event, images: [image])
        try db.pool.write { db in
            try self.insertJob(db, id: "job-1", image: image.id)
            try self.insertRun(db, id: "run-capture", job: "job-1", image: image.id)
            try self.insertRun(db, id: "run-sample", job: "job-1", image: nil)
        }
        try store.deleteEvents(ids: [event.id])
        try db.pool.read { db in
            let runIDs = try String.fetchAll(db, sql: "SELECT id FROM model_runs ORDER BY id")
            let jobCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis_jobs")
            #expect(runIDs == ["run-sample"])
            #expect(jobCount == 1)
        }
    }

    @Test func aDatabaseWithOnlyV1GainsTheV2TablesWithoutLosingTheCapture() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        let event = makeEventRecord()
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v1")
            try pool.write { db in
                try db.execute(sql: "INSERT INTO capture_events VALUES (?, datetime('now'), 'menu', 'complete', NULL, 1)", arguments: [event.id])
            }
            let hasJobsTable = try pool.read { db in try db.tableExists("analysis_jobs") }
            #expect(!hasJobsTable)
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            let hasJobs = try db.tableExists("analysis_jobs"), hasRuns = try db.tableExists("model_runs")
            #expect(hasJobs && hasRuns)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_events") == 1)
        }
    }
}
