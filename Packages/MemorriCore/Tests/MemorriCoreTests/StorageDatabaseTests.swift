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
                     "request_json", "raw_answer", "step"])      // "step" comes from migration v3
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

    // MARK: migration "v3" (spec 004)

    private static let v3Columns: [(String, [String])] = [
        ("contexts", ["id", "name", "timezone", "created_at", "updated_at"]),
        ("context_hints", ["id", "context_id", "kind", "value"]),
        ("capture_windows", ["id", "image_id", "z", "app_name", "bundle_id", "title", "x", "y", "width", "height"]),
        ("ocr_reads", ["image_id", "read_at", "line_count", "recogniser", "duration_ms"]),
        ("ocr_lines", ["image_id", "n", "text", "x", "y", "width", "height", "confidence"]),
        ("image_analysis", ["image_id", "screen_kind", "kind_confidence", "classify_version", "prompt_version", "schema_version",
                            "model", "picture_long_edge", "timezone", "timezone_source", "finding_count", "line_cap_applied",
                            "discarded_json", "extract_run_id", "analysed_at"]),
        ("image_context", ["image_id", "context_id", "source", "score", "matched_json", "runner_up_json", "decided_at"]),
        ("capture_tags", ["image_id", "key", "value", "confidence", "source"]),
        ("findings", ["id", "image_id", "run_id", "kind", "title", "all_day", "start_at", "end_at", "due_at", "remind_at", "timezone",
                      "people_json", "place", "notes", "cited_lines_json", "confidence", "provenance_json", "unresolved_json",
                      "tags_json", "created_at"]),
    ]

    @Test func v3CreatesTheTablesWithTheListedColumns() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            for (table, expected) in Self.v3Columns {
                let names = try db.columns(in: table).map(\.name)
                #expect(names == expected, "columns of \(table)")
            }
            #expect(try db.columns(in: "model_runs").map(\.name).last == "step")
            let step = try self.column("model_runs", "step", in: db)
            #expect(step.isNotNull && step.defaultValueSQL == "'test'")
        }
    }

    private func seedPicture(_ db: Database, image: String = "img-1") throws {
        try db.execute(sql: "INSERT INTO capture_events VALUES ('ev-1', datetime('now'), 'menu', 'complete', NULL, 1)")
        try db.execute(sql: """
            INSERT INTO capture_images (id, event_id, display_id, display_name, pixel_width, pixel_height, scale, full_path, model_path,
                                        model_width, model_height, full_bytes, model_bytes, missing)
            VALUES (?, 'ev-1', 1, 'D', 100, 50, 1, 'f', 'm', 100, 50, 1, 1, 0)
            """, arguments: [image])
    }

    private func fillPictureTables(_ db: Database, image: String = "img-1") throws {
        try db.execute(sql: "INSERT INTO capture_windows VALUES ('w1', ?, 0, 'App', 'com.app', 'Title', 0, 0, 10, 10)", arguments: [image])
        try db.execute(sql: "INSERT INTO ocr_reads VALUES (?, datetime('now'), 1, 'vision', 5)", arguments: [image])
        try db.execute(sql: "INSERT INTO ocr_lines VALUES (?, 1, 'text', 0, 0, 10, 10, 0.9)", arguments: [image])
        try db.execute(sql: """
            INSERT INTO image_analysis VALUES (?, 'email', 0.9, 'classify-v1', 'extract-email-v1', 'schema-email-v1', 'm', 2048, 'Europe/Madrid',
                                               'mac', 1, 0, '[]', NULL, datetime('now'))
            """, arguments: [image])
        try db.execute(sql: "INSERT INTO image_context VALUES (?, NULL, 'none', 0, '[]', NULL, datetime('now'))", arguments: [image])
        try db.execute(sql: "INSERT INTO capture_tags VALUES (?, 'application', 'Outlook', 0.9, 'visual')", arguments: [image])
        try db.execute(sql: """
            INSERT INTO findings VALUES ('f1', ?, NULL, 'task', 'T', 0, NULL, NULL, NULL, NULL, 'Europe/Madrid', '[]', NULL, NULL, '[1]', 0.9,
                                         '{}', '{}', '[]', datetime('now'))
            """, arguments: [image])
    }

    private func count(_ db: Database, _ table: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }

    @Test func deletingACaptureRemovesEveryRowThatBelongsToItAndKeepsContexts() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try self.fillPictureTables(db)
            try db.execute(sql: "INSERT INTO contexts VALUES ('c1', 'Customer A', 'America/New_York', datetime('now'), datetime('now'))")
            try db.execute(sql: "INSERT INTO context_hints VALUES ('h1', 'c1', 'app', 'Outlook')")
        }
        try CaptureStore(database: db).deleteEvents(ids: ["ev-1"])
        try db.pool.read { db in
            for table in ["capture_windows", "ocr_reads", "ocr_lines", "image_analysis", "image_context", "capture_tags", "findings"] {
                let rows = try self.count(db, table)
                #expect(rows == 0, "\(table) should be empty")
            }
            let contexts = try self.count(db, "contexts"), hints = try self.count(db, "context_hints")
            #expect(contexts == 1 && hints == 1)
        }
    }

    @Test func otherCapturesKeepTheirRows() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try self.fillPictureTables(db)
            try db.execute(sql: "INSERT INTO capture_events VALUES ('ev-2', datetime('now'), 'menu', 'complete', NULL, 1)")
            try db.execute(sql: """
                INSERT INTO capture_images (id, event_id, display_id, pixel_width, pixel_height, scale, full_path, model_path,
                                            model_width, model_height, full_bytes, model_bytes, missing)
                VALUES ('img-2', 'ev-2', 1, 100, 50, 1, 'f', 'm', 100, 50, 1, 1, 0)
                """)
            try db.execute(sql: "INSERT INTO ocr_lines VALUES ('img-2', 1, 'other', 0, 0, 10, 10, 0.9)")
        }
        try CaptureStore(database: db).deleteEvents(ids: ["ev-1"])
        try db.pool.read { db in
            let lines = try self.count(db, "ocr_lines")
            #expect(lines == 1)
        }
    }

    @Test func contextDeletionCascadesHintsAndLeavesPicturesUnassigned() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try db.execute(sql: "INSERT INTO contexts VALUES ('c1', 'A', NULL, datetime('now'), datetime('now'))")
            try db.execute(sql: "INSERT INTO context_hints VALUES ('h1', 'c1', 'keyword', 'acme')")
            try db.execute(sql: "INSERT INTO image_context VALUES ('img-1', 'c1', 'auto', 3, '[]', NULL, datetime('now'))")
            try db.execute(sql: "DELETE FROM contexts WHERE id = 'c1'")
            let hints = try self.count(db, "context_hints"), rows = try self.count(db, "image_context")
            #expect(hints == 0 && rows == 1)
            #expect(try String.fetchOne(db, sql: "SELECT context_id FROM image_context") == nil)
        }
    }

    @Test func v3KeysAndConstraints() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try self.fillPictureTables(db)
            // duplicate line number for one picture
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO ocr_lines VALUES ('img-1', 1, 'x', 0, 0, 1, 1, 1)") }
            // same tag key with another value is fine, the same value twice is not; the key is free text
            try db.execute(sql: "INSERT INTO capture_tags VALUES ('img-1', 'application', 'Teams', 0.5, 'visual')")
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO capture_tags VALUES ('img-1', 'application', 'Teams', 0.5, 'visual')") }
            try db.execute(sql: "INSERT INTO capture_tags VALUES ('img-1', 'a_future_key', 'v', 1, 'code')")
            // constrained values
            #expect(throws: (any Error).self) { try db.execute(sql: "UPDATE findings SET kind = 'meeting'") }
            #expect(throws: (any Error).self) { try db.execute(sql: "UPDATE image_analysis SET screen_kind = 'video'") }
            #expect(throws: (any Error).self) { try db.execute(sql: "UPDATE image_analysis SET timezone_source = 'guess'") }
            #expect(throws: (any Error).self) { try db.execute(sql: "UPDATE image_context SET source = 'magic'") }
            try db.execute(sql: "INSERT INTO contexts VALUES ('c1', 'Acme', NULL, datetime('now'), datetime('now'))")
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO context_hints VALUES ('h9', 'c1', 'colour', 'red')") }
            // names are unique ignoring case
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO contexts VALUES ('c2', 'acme', NULL, datetime('now'), datetime('now'))") }
        }
    }

    @Test func aV2DatabaseGainsV3WithoutLosingData() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v2")
            try pool.write { db in
                try self.seedPicture(db)
                try db.execute(sql: "INSERT INTO analysis_jobs (id, kind, image_id, state, created_at, updated_at) VALUES ('j', 'test', NULL, 'finished', datetime('now'), datetime('now'))")
                try db.execute(sql: """
                    INSERT INTO model_runs (id, job_id, image_id, attempt, model, think, temperature, image_long_edge, prompt_version,
                                            schema_version, started_at, duration_ms, outcome, request_json)
                    VALUES ('r', 'j', 'img-1', 1, 'm', 'off', 0, 2048, 'test-v1', 'test-v1', datetime('now'), 1, 'success', '{}')
                    """)
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            for (table, _) in Self.v3Columns { #expect(try db.tableExists(table), "\(table) exists") }
            let captures = try self.count(db, "capture_images"), jobs = try self.count(db, "analysis_jobs"), runs = try self.count(db, "model_runs")
            #expect(captures == 1 && jobs == 1 && runs == 1)
            #expect(try String.fetchOne(db, sql: "SELECT step FROM model_runs") == "test")
        }
    }
}
