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
                    ["id", "kind", "image_id", "state", "attempts", "not_before", "failure_reason", "created_at", "updated_at", "priority", "trial_id"])   // priority: v8, trial_id: v10
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
            #expect(jobIndexes.contains(["state", "priority", "created_at"]))     // v8 replaced (state, created_at)
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
        ("capture_windows", ["id", "image_id", "z", "app_name", "bundle_id", "title", "x", "y", "width", "height", "stack"]),   // stack: migration v4
        ("ocr_reads", ["image_id", "read_at", "line_count", "recogniser", "duration_ms"]),
        ("ocr_lines", ["image_id", "n", "text", "x", "y", "width", "height", "confidence"]),
        ("image_analysis", ["image_id", "screen_kind", "kind_confidence", "classify_version", "prompt_version", "schema_version",
                            "model", "picture_long_edge", "timezone", "timezone_source", "finding_count", "line_cap_applied",
                            "discarded_json", "extract_run_id", "analysed_at", "reconciled_at", "reconcile_error",
                            "reference_at", "reference_source", "windows_read"]),   // reconciled_at, reconcile_error: v5; the last three: v8
        ("image_context", ["image_id", "context_id", "source", "score", "matched_json", "runner_up_json", "decided_at"]),
        ("capture_tags", ["image_id", "key", "value", "confidence", "source"]),
        ("findings", ["id", "image_id", "run_id", "kind", "title", "all_day", "start_at", "end_at", "due_at", "remind_at", "timezone",
                      "people_json", "place", "notes", "cited_lines_json", "confidence", "provenance_json", "unresolved_json",
                      "tags_json", "created_at", "window_key"]),     // window_key: migration v8
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
        try db.execute(sql: "INSERT INTO capture_windows (id, image_id, z, app_name, bundle_id, title, x, y, width, height) VALUES ('w1', ?, 0, 'App', 'com.app', 'Title', 0, 0, 10, 10)", arguments: [image])
        try db.execute(sql: "INSERT INTO ocr_reads VALUES (?, datetime('now'), 1, 'vision', 5)", arguments: [image])
        try db.execute(sql: "INSERT INTO ocr_lines VALUES (?, 1, 'text', 0, 0, 10, 10, 0.9)", arguments: [image])
        try db.execute(sql: """
            INSERT INTO image_analysis (image_id, screen_kind, kind_confidence, classify_version, prompt_version, schema_version, model,
                picture_long_edge, timezone, timezone_source, finding_count, line_cap_applied, discarded_json, extract_run_id, analysed_at)
            VALUES (?, 'email', 0.9, 'classify-v1', 'extract-email-v1', 'schema-email-v1', 'm', 2048, 'Europe/Madrid',
                                               'mac', 1, 0, '[]', NULL, datetime('now'))
            """, arguments: [image])
        try db.execute(sql: "INSERT INTO image_context VALUES (?, NULL, 'none', 0, '[]', NULL, datetime('now'))", arguments: [image])
        try db.execute(sql: "INSERT INTO capture_tags VALUES (?, 'application', 'Outlook', 0.9, 'visual')", arguments: [image])
        try db.execute(sql: """
            INSERT INTO findings (id, image_id, run_id, kind, title, all_day, start_at, end_at, due_at, remind_at, timezone, people_json, place, notes,
                                  cited_lines_json, confidence, provenance_json, unresolved_json, tags_json, created_at)
            VALUES ('f1', ?, NULL, 'task', 'T', 0, NULL, NULL, NULL, NULL, 'Europe/Madrid', '[]', NULL, NULL, '[1]', 0.9,
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

    // MARK: migration "v5" (spec 005)

    private static let v5Columns: [(String, [String])] = [
        ("items", ["id", "kind", "family", "status", "merged_into", "context_id", "title", "all_day", "start_at", "end_at", "due_at", "remind_at",
                   "timezone", "day_key", "people_json", "place", "notes", "confidence", "user_touched", "first_seen", "last_seen",
                   "created_at", "updated_at",
                   "needs_review", "review_reasons_json", "approved_at", "approved_values_json"]),      // the last four: migration v6
        ("sightings", ["id", "item_id", "image_id", "finding_id", "captured_at", "title", "cited_lines_json", "confidence", "decision_json", "created_at",
                       "window_app", "window_title"]),       // the window names: migration v8
        ("observations", ["id", "item_id", "sighting_id", "field", "value_json", "source", "confidence", "observed_at"]),
        ("field_locks", ["item_id", "field", "observation_id", "locked_at"]),
        ("item_aliases", ["item_id", "normalised", "title"]),
        ("keep_apart", ["item_a", "item_b", "op_id"]),
        ("possible_duplicates", ["item_a", "item_b", "scores_json", "created_at"]),
        ("reconcile_ops", ["id", "kind", "by_user", "item_ids_json", "moved_json", "before_json", "detail_json", "undone_by", "created_at"]),
        ("reconcile_op_items", ["op_id", "item_id"]),
        ("title_embeddings", ["normalised", "model", "vector", "created_at"]),
    ]

    private func insertItem(_ db: Database, id: String, status: String = "active", family: String = "event", kind: String = "appointment") throws {
        try db.execute(sql: """
            INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'Daily standup', 'Europe/Madrid', 0.8, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
            """, arguments: [id, kind, family, status])
    }

    private func insertSighting(_ db: Database, id: String, item: String, image: String = "img-1") throws {
        try db.execute(sql: """
            INSERT INTO sightings (id, item_id, image_id, finding_id, captured_at, title, cited_lines_json, confidence, decision_json, created_at)
            VALUES (?, ?, ?, 'f1', datetime('now'), 'Daily standup', '[1]', 0.8, '{}', datetime('now'))
            """, arguments: [id, item, image])
    }

    @Test func v5CreatesTheTablesWithTheListedColumns() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            for (table, expected) in Self.v5Columns {
                let v1 = try db.columns(in: table).map(\.name)
                #expect(v1 == expected, "columns of \(table)")
            }
            let analysis = try db.columns(in: "image_analysis").map(\.name)
            #expect(analysis.contains("reconciled_at") && analysis.contains("reconcile_error"))
            let v2 = try self.column("image_analysis", "reconciled_at", in: db).isNotNull
            #expect(v2 == false)
            let v3 = try self.column("image_analysis", "reconcile_error", in: db).isNotNull
            #expect(v3 == false)
            let v4 = try self.column("reconcile_ops", "by_user", in: db)
            #expect(v4.isNotNull)
            let v5 = try self.column("observations", "sighting_id", in: db).isNotNull
            #expect(v5 == false)
            let v6 = try self.column("items", "day_key", in: db).isNotNull
            #expect(v6 == false)
            let v7 = try self.column("items", "user_touched", in: db).defaultValueSQL
            #expect(v7 == "0")
        }
    }

    @Test func v5ConstrainsStatusFamilyAndKind() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            for status in ["active", "dismissed", "merged"] { try self.insertItem(db, id: "s-\(status)", status: status) }
            for family in ["event", "todo"] { try self.insertItem(db, id: "f-\(family)", family: family) }
            for kind in ["appointment", "task", "reminder", "deadline"] { try self.insertItem(db, id: "k-\(kind)", kind: kind) }
            #expect(throws: (any Error).self) { try self.insertItem(db, id: "bad-s", status: "gone") }
            #expect(throws: (any Error).self) { try self.insertItem(db, id: "bad-f", family: "other") }
            #expect(throws: (any Error).self) { try self.insertItem(db, id: "bad-k", kind: "meeting") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO reconcile_ops VALUES ('o', 'teleport', 1, '[]', '[]', '{}', '{}', NULL, datetime('now'))") }
            try db.execute(sql: "INSERT INTO reconcile_ops VALUES ('o', 'auto_merge', 0, '[]', '[]', '{}', '{}', NULL, datetime('now'))")
        }
    }

    @Test func v5KeysForeignKeysAndCascades() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try db.execute(sql: "INSERT INTO contexts VALUES ('c1', 'Acme', NULL, datetime('now'), datetime('now'))")
            try self.insertItem(db, id: "i1"); try self.insertItem(db, id: "i2")
            try db.execute(sql: "UPDATE items SET context_id = 'c1' WHERE id = 'i1'")
            try self.insertSighting(db, id: "s1", item: "i1")
            try db.execute(sql: "INSERT INTO observations VALUES ('o1', 'i1', 's1', 'title', '\"Daily standup\"', 'read', 0.8, datetime('now'))")
            try db.execute(sql: "INSERT INTO observations VALUES ('o2', 'i1', NULL, 'title', '\"Mine\"', 'user', 1, datetime('now'))")
            try db.execute(sql: "INSERT INTO field_locks VALUES ('i1', 'title', 'o2', datetime('now'))")
            try db.execute(sql: "INSERT INTO item_aliases VALUES ('i1', 'dailystandup', 'Daily standup')")
            try db.execute(sql: "INSERT INTO keep_apart VALUES ('i1', 'i2', 'op')")
            try db.execute(sql: "INSERT INTO possible_duplicates VALUES ('i1', 'i2', '{}', datetime('now'))")
            try db.execute(sql: "INSERT INTO reconcile_ops VALUES ('op', 'merge', 1, '[]', '[]', '{}', '{}', NULL, datetime('now'))")
            try db.execute(sql: "INSERT INTO reconcile_op_items VALUES ('op', 'i1')")
            try db.execute(sql: "INSERT INTO title_embeddings VALUES ('dailystandup', 'e5', x'00', datetime('now'))")
            // keys
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO field_locks VALUES ('i1', 'title', 'o2', datetime('now'))") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO item_aliases VALUES ('i1', 'dailystandup', 'again')") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO keep_apart VALUES ('i1', 'i2', 'op2')") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO possible_duplicates VALUES ('i1', 'i2', '{}', datetime('now'))") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO reconcile_op_items VALUES ('op', 'i1')") }
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO title_embeddings VALUES ('dailystandup', 'e5', x'01', datetime('now'))") }
            try db.execute(sql: "INSERT INTO title_embeddings VALUES ('dailystandup', 'other-model', x'01', datetime('now'))")
            // foreign keys
            #expect(throws: (any Error).self) { try db.execute(sql: "UPDATE items SET merged_into = 'nobody' WHERE id = 'i2'") }
            #expect(throws: (any Error).self) { try self.insertSighting(db, id: "s9", item: "i1", image: "no-such-image") }
            // deleting the capture removes the sighting and its observation, nothing else
            try db.execute(sql: "DELETE FROM capture_images WHERE id = 'img-1'")
            let v8 = try self.count(db, "sightings")
            #expect(v8 == 0)
            let userObservations = try self.count(db, "observations")           // the user's
            #expect(userObservations == 1)
            let v9 = try self.count(db, "items")
            #expect(v9 == 2)
            let v10 = try self.count(db, "item_aliases")
            #expect(v10 == 1)
            let v11 = try self.count(db, "field_locks")
            #expect(v11 == 1)
            // deleting a context keeps the item and clears its context
            try db.execute(sql: "DELETE FROM contexts WHERE id = 'c1'")
            let contextRow = try Row.fetchOne(db, sql: "SELECT context_id FROM items WHERE id = 'i1'")
            #expect(contextRow?["context_id"] as String? == nil)
            let v13 = try self.count(db, "items")
            #expect(v13 == 2)
            // deleting an item removes everything that hangs on it
            try db.execute(sql: "DELETE FROM items WHERE id = 'i1'")
            for table in ["observations", "field_locks", "item_aliases", "keep_apart", "possible_duplicates"] {
                let v14 = try self.count(db, table)
                #expect(v14 == 0, Comment(rawValue: table))
            }
            // the history of an item outlives it
            let v15 = try self.count(db, "reconcile_op_items")
            #expect(v15 == 1)
        }
    }

    @Test func v5IndexesExist() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        // Read the index definitions from the schema itself (`indexes(on:)` returns nothing for `items`).
        let sql: [String: [String]] = try db.pool.read { db in
            var result: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL") {
                let table: String = row["tbl_name"]
                let definition: String = row["sql"]
                result[table, default: []].append(definition)
            }
            return result
        }
        func has(_ table: String, _ columns: String) -> Bool {
            sql[table]?.contains { $0.hasSuffix("(\(columns))") } == true
        }
        #expect(has("items", "\"context_id\", \"family\", \"day_key\""))
        #expect(has("items", "\"status\""))
        #expect(has("sightings", "\"item_id\""))
        #expect(has("sightings", "\"image_id\""))
        #expect(has("observations", "\"item_id\", \"field\""))
        #expect(has("reconcile_ops", "\"created_at\""))
        #expect(has("reconcile_op_items", "\"item_id\""))
    }

    @Test func aV4DatabaseGainsV5WithoutLosingData() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v4")
            try pool.write { db in
                try self.seedPicture(db)
                try self.fillPictureTables(db)
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            for (table, _) in Self.v5Columns {
                let exists = try db.tableExists(table)
                #expect(exists, "\(table) exists")
            }
            let v16 = try self.count(db, "capture_images")
            #expect(v16 == 1)
            let v17 = try self.count(db, "findings")
            #expect(v17 == 1)
            let v18 = try self.count(db, "image_analysis")
            #expect(v18 == 1)
            let v19 = try Row.fetchOne(db, sql: "SELECT reconciled_at, reconcile_error FROM image_analysis")?["reconciled_at"] as Date?
            #expect(v19 == nil)
        }
    }

    // MARK: migration "v6" (spec 006)

    @Test func v6CreatesTheEvidenceTableAndTheReviewColumns() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            let evidence = try db.columns(in: "evidence").map(\.name)
            #expect(evidence == ["id", "item_id", "sighting_id", "image_id", "captured_at", "display_name", "title", "cited_lines_json", "region_json",
                                 "file_path", "reason", "bytes", "created_at", "geometry", "window_app", "window_title"])       // "geometry" arrived with v7, the window names with v8
            let needs = try self.column("items", "needs_review", in: db), reasons = try self.column("items", "review_reasons_json", in: db)
            let approved = try self.column("items", "approved_at", in: db), values = try self.column("items", "approved_values_json", in: db)
            #expect(needs.isNotNull && reasons.isNotNull && !approved.isNotNull && !values.isNotNull)
            #expect(needs.defaultValueSQL == "0" && reasons.defaultValueSQL == "'[]'")
            let sql = try Row.fetchAll(db, sql: "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
                .map { ($0["tbl_name"] as String) + ": " + ($0["sql"] as String) }
            #expect(sql.contains { $0.hasPrefix("items:") && $0.hasSuffix("(\"needs_review\", \"status\")") })
            #expect(sql.contains { $0.hasPrefix("evidence:") && $0.hasSuffix("(\"item_id\", \"captured_at\")") })
            #expect(sql.contains { $0.hasPrefix("evidence:") && $0.hasSuffix("(\"image_id\")") })
            #expect(sql.contains { $0.hasPrefix("evidence:") && $0.contains("UNIQUE") && $0.contains("\"sighting_id\" IS NOT NULL") })
        }
    }

    @Test func deletingAnItemRemovesItsEvidenceAndDeletingASightingKeepsIt() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try self.insertItem(db, id: "item-1")
            try self.insertSighting(db, id: "s-1", item: "item-1")
            for (id, sighting) in [("e-1", "s-1"), ("e-2", nil as String?)] {
                try db.execute(sql: """
                    INSERT INTO evidence (id, item_id, sighting_id, image_id, captured_at, title, cited_lines_json, region_json, created_at)
                    VALUES (?, 'item-1', ?, 'img-1', datetime('now'), 'Daily standup', '[1]', '{}', datetime('now'))
                    """, arguments: [id, sighting])
            }
            try db.execute(sql: "DELETE FROM sightings WHERE id = 's-1'")
            let keptRows = try Row.fetchAll(db, sql: "SELECT id, sighting_id FROM evidence ORDER BY id")
            #expect(keptRows.count == 2 && (keptRows[0]["sighting_id"] as String?) == nil)
            try db.execute(sql: "DELETE FROM items WHERE id = 'item-1'")
            #expect(try self.count(db, "evidence") == 0)
        }
    }

    @Test func aSightingHasAtMostOneEvidenceRow() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try self.insertItem(db, id: "item-1")
            try self.insertSighting(db, id: "s-1", item: "item-1")
            let insert = """
                INSERT INTO evidence (id, item_id, sighting_id, image_id, captured_at, title, cited_lines_json, region_json, created_at)
                VALUES (?, 'item-1', 's-1', 'img-1', datetime('now'), 't', '[1]', '{}', datetime('now'))
                """
            try db.execute(sql: insert, arguments: ["e-1"])
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: ["e-2"]) }
        }
    }

    @Test func approveIsAKnownOperationKindAndOlderOperationsSurviveTheMigration() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v5")
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
                    VALUES ('op-1', 'merge', 1, '["a"]', '[]', '{}', '{}', NULL, datetime('now'))
                    """)
                try db.execute(sql: "INSERT INTO reconcile_op_items (op_id, item_id) VALUES ('op-1', 'a')")
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.write { db in
            #expect(try self.count(db, "reconcile_ops") == 1 && self.count(db, "reconcile_op_items") == 1)
            try db.execute(sql: """
                INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
                VALUES ('op-2', 'approve', 1, '["a"]', '[]', '{}', '{}', NULL, datetime('now'))
                """)
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                    INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
                    VALUES ('op-3', 'bogus', 1, '[]', '[]', '{}', '{}', NULL, datetime('now'))
                    """)
            }
            // the history still hangs on its operation
            try db.execute(sql: "DELETE FROM reconcile_ops WHERE id = 'op-1'")
            #expect(try self.count(db, "reconcile_op_items") == 0)
        }
    }

    @Test func aV5DatabaseGainsV6WithoutLosingItems() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v5")
            try pool.write { db in try self.insertItem(db, id: "item-1") }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT title, needs_review, review_reasons_json, approved_at FROM items WHERE id = 'item-1'"))
            #expect(row["title"] as String == "Daily standup" && (row["approved_at"] as Date?) == nil)
            #expect(try db.tableExists("evidence"))
        }
    }

    @Test func theMigrationComputesTheReviewStateOfItemsThatExist() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v6")
            try pool.write { db in
                try self.insertItem(db, id: "fine")
                try self.insertItem(db, id: "faint")
                try db.execute(sql: "UPDATE items SET confidence = 0.5 WHERE id = 'faint'")
                try self.insertItem(db, id: "gone", status: "merged")
                try db.execute(sql: "UPDATE items SET confidence = 0.5 WHERE id = 'gone'")
                try self.insertItem(db, id: "dismissed", status: "dismissed")
                try db.execute(sql: "UPDATE items SET confidence = 0.5 WHERE id = 'dismissed'")
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            func state(_ id: String) throws -> (Int, String) {
                let row = try #require(try Row.fetchOne(db, sql: "SELECT needs_review, review_reasons_json FROM items WHERE id = ?", arguments: [id]))
                return (row["needs_review"], row["review_reasons_json"])
            }
            let fine = try state("fine"), faint = try state("faint"), gone = try state("gone"), dismissed = try state("dismissed")
            #expect(fine == (0, "[]"))
            #expect(faint == (1, "[\"low-confidence\"]"))
            #expect(gone == (0, "[]") && dismissed == (0, "[]"))
        }
    }

    // MARK: migration "v8" (spec 011)

    @Test func v8CreatesTheWindowReadingsTable() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            let columns = try db.columns(in: "window_readings")
            #expect(columns.map(\.name) == ["image_id", "window_key", "app_name", "title", "frame_json", "visible_json", "visible_share", "relevant",
                                           "kind", "confidence", "remote", "run_id", "prompt_version", "created_at"])
            let notNull = Set(columns.filter(\.isNotNull).map(\.name))
            #expect(notNull == ["image_id", "window_key", "frame_json", "visible_json", "visible_share", "relevant", "confidence", "remote",
                                "prompt_version", "created_at"])
            let remote = try self.column("window_readings", "remote", in: db)
            #expect(remote.defaultValueSQL == "0")
            #expect(try db.primaryKey("window_readings").columns == ["image_id", "window_key"])
            let references = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(window_readings)")
            #expect(references.contains { ($0["table"] as String) == "capture_images" && ($0["on_delete"] as String) == "CASCADE" })
        }
    }

    @Test func v8AddsTheWindowColumnsToTheTablesItEdits() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            let key = try self.column("findings", "window_key", in: db)
            #expect(!key.isNotNull && key.type.uppercased() == "TEXT")
            let reference = try self.column("image_analysis", "reference_at", in: db), source = try self.column("image_analysis", "reference_source", in: db)
            let read = try self.column("image_analysis", "windows_read", in: db)
            #expect(!reference.isNotNull && !source.isNotNull)
            #expect(read.isNotNull && read.defaultValueSQL == "1")
            for table in ["sightings", "evidence"] {
                let app = try self.column(table, "window_app", in: db), title = try self.column(table, "window_title", in: db)
                #expect(!app.isNotNull && !title.isNotNull, "\(table) window names can be null")
            }
            let priority = try self.column("analysis_jobs", "priority", in: db)
            #expect(priority.isNotNull && priority.defaultValueSQL == "0")
            let indexes = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'analysis_jobs' AND sql IS NOT NULL")
            let names = indexes.map { $0["name"] as String }
            #expect(!names.contains("analysis_jobs_state_created_at"))
            #expect(indexes.contains { ($0["sql"] as String).hasSuffix("(\"state\", \"priority\", \"created_at\")") })
        }
    }

    @Test func deletingACaptureRemovesItsWindowReadings() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.seedPicture(db)
            try db.execute(sql: """
                INSERT INTO window_readings (image_id, window_key, frame_json, visible_json, visible_share, relevant, confidence, prompt_version, created_at)
                VALUES ('img-1', 'w0', '{}', '[]', 1, 1, 0.9, 'windows-v1', datetime('now'))
                """)
            let before = try self.count(db, "window_readings")
            #expect(before == 1)
            try db.execute(sql: "DELETE FROM capture_images WHERE id = 'img-1'")
            let after = try self.count(db, "window_readings")
            #expect(after == 0)
        }
    }

    @Test func aV7DatabaseMigratesToV8WithItsRowsAndNoWindowKeys() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v7")
            try pool.write { db in
                try self.seedPicture(db)
                try db.execute(sql: """
                    INSERT INTO findings (id, image_id, run_id, kind, title, all_day, start_at, end_at, due_at, remind_at, timezone, people_json, place,
                        notes, cited_lines_json, confidence, provenance_json, unresolved_json, tags_json, created_at)
                    VALUES ('f1', 'img-1', NULL, 'task', 'T', 0, NULL, NULL, NULL, NULL, 'Europe/Madrid', '[]', NULL, NULL, '[1]', 0.9, '{}', '{}', '[]', datetime('now'))
                    """)
                try self.insertJob(db, id: "job-1", kind: "analyse", image: "img-1")
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            let key = try Row.fetchOne(db, sql: "SELECT window_key FROM findings WHERE id = 'f1'")?["window_key"] as String?
            let priority = try Int.fetchOne(db, sql: "SELECT priority FROM analysis_jobs WHERE id = 'job-1'")
            #expect(key == nil)
            #expect(priority == 0)
        }
    }

    // MARK: migration "v10" (spec 008)

    @Test func aV9DatabaseMigratesToV10KeepingItsOperationLogAndItemHistory() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v9")
            try pool.write { db in
                try self.insertItem(db, id: "i1", title: "Daily standup")
                try db.execute(sql: """
                    INSERT INTO reconcile_ops (id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at)
                    VALUES ('op1', 'approve', 1, '["i1"]', '[]', '{}', '{"note":"kept"}', NULL, '2026-10-01 10:00:00.000'),
                           ('op2', 'edit', 1, '["i1"]', '[]', '{}', '{}', 'op3', '2026-10-01 11:00:00.000')
                    """)
                try db.execute(sql: "INSERT INTO reconcile_op_items (op_id, item_id) VALUES ('op1', 'i1'), ('op2', 'i1')")
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            let ops = try Row.fetchAll(db, sql: "SELECT id, kind, detail_json, undone_by FROM reconcile_ops ORDER BY id")
            #expect(ops.map { $0["id"] as String } == ["op1", "op2"] && ops[0]["detail_json"] as String == "{\"note\":\"kept\"}" && ops[1]["undone_by"] as String? == "op3")
            let links = try Row.fetchAll(db, sql: "SELECT op_id, item_id FROM reconcile_op_items ORDER BY op_id")
            #expect(links.map { $0["op_id"] as String } == ["op1", "op2"])
            #expect(try db.indexes(on: "reconcile_ops").contains { $0.name == "reconcile_ops_created_at" })
            let foreign = try db.foreignKeys(on: "reconcile_op_items").map(\.destinationTable)
            #expect(foreign.contains("reconcile_ops"))
        }
        let history = try OperationLog(database: db).ops(forItem: "i1")
        #expect(history.map(\.id) == ["op2", "op1"])
    }

    @Test func v10CreatesTheTrialTablesAndKeepsTheOperationLog() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            for table in ["trials", "trial_images", "trial_findings"] { #expect(try db.tableExists(table), "\(table) should exist") }
            #expect(try db.columns(in: "trials").map(\.name) == ["id", "model", "prompt_version", "think", "state", "created_at", "finished_at"])
            #expect(try db.columns(in: "trial_images").map(\.name) == ["trial_id", "image_id", "state", "reason", "finding_count", "duration_ms"])
            let findings = try db.columns(in: "findings").map(\.name).filter { $0 != "run_id" }
            let proposals = try db.columns(in: "trial_findings").map(\.name)
            #expect(Set(findings).isSubset(of: Set(proposals)))          // a proposal keeps every column of a finding
        }
    }

    // MARK: migration "v11" (spec 009)

    @Test func aV10DatabaseMigratesToV11KeepingItsItemsAndAddingTheSyncTables() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v10")
            try pool.write { try self.insertItem($0, id: "i1", title: "Daily standup") }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.write { db in
            #expect(try String.fetchAll(db, sql: "SELECT id FROM items") == ["i1"])
            for table in ["sync_links", "sync_runs"] { #expect(try db.tableExists(table), "\(table) should exist") }
            #expect(try db.columns(in: "sync_links").map(\.name) == ["item_id", "kind", "ek_id", "container_id", "hash", "hash_version", "fields_json", "state", "failure", "synced_at", "created_at"])
            #expect(try db.indexes(on: "sync_links").contains { $0.name == "sync_links_ek_id" })
            try db.execute(sql: """
                INSERT INTO sync_links (item_id, kind, ek_id, container_id, hash, hash_version, fields_json, state, synced_at, created_at)
                VALUES ('i1', 'event', 'E1', 'cal', 'h', 1, '{}', 'synced', datetime('now'), datetime('now'))
                """)
            // A link goes with its item.
            try db.execute(sql: "DELETE FROM items WHERE id = 'i1'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_links") == 0)
        }
    }

    // MARK: migration "v9" (spec 007)

    private func insertItem(_ db: Database, id: String, title: String, notes: String? = nil, place: String? = nil, people: String = "[]", status: String = "active") throws {
        try db.execute(sql: """
            INSERT INTO items (id, kind, family, status, title, timezone, people_json, place, notes, confidence, first_seen, last_seen, created_at, updated_at)
            VALUES (?, 'appointment', 'event', ?, ?, 'Europe/Madrid', ?, ?, ?, 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'))
            """, arguments: [id, status, title, people, place, notes])
    }

    @Test func v9CreatesTheSearchTables() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.read { db in
            let v1 = try db.columns(in: "search_items").map(\.name)
            #expect(v1 == ["item_id", "title", "aliases", "notes", "place", "people"])
            let v2 = try db.columns(in: "search_captures").map(\.name)
            #expect(v2 == ["image_id", "body"])
            let v3 = try db.columns(in: "search_meta").map(\.name)
            #expect(v3 == ["key", "value"])
            for table in ["search_items", "search_captures"] {
                let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [table]) ?? ""
                #expect(sql.contains("fts5") && sql.contains("remove_diacritics 2") && sql.contains("prefix"), "\(table)")
            }
            let triggers = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'search_%'"))
            #expect(triggers == ["search_items_after_insert", "search_items_after_update", "search_items_after_delete",
                                 "search_aliases_after_insert", "search_aliases_after_update", "search_aliases_after_delete",
                                 "search_captures_after_read_delete"])
            let v4 = try db.primaryKey("search_meta").columns
            #expect(v4 == ["key"])
        }
    }

    @Test func theItemTriggersKeepOneRowPerItemThatIsNotMerged() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let db = try #require(opened(try StorageDatabase.open(paths: makePaths(temp))))
        try db.pool.write { db in
            try self.insertItem(db, id: "i1", title: "Café - Pruebas", notes: "sala grande", people: "[\"Ana\",\"Luis\"]")
            try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES ('i1', 'pruebas', 'Pruebas Café')")
            let row = try Row.fetchOne(db, sql: "SELECT * FROM search_items WHERE item_id = 'i1'")
            #expect(row?["title"] as String? == "Café - Pruebas" && row?["notes"] as String? == "sala grande")
            #expect(row?["people"] as String? == "Ana Luis" && row?["aliases"] as String? == "Pruebas Café")
            try db.execute(sql: "UPDATE items SET title = 'Pruebas finales' WHERE id = 'i1'")
            let v5 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items WHERE item_id = 'i1'")
            #expect(v5 == 1)
            try db.execute(sql: "UPDATE items SET status = 'merged' WHERE id = 'i1'")
            let v6 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items WHERE item_id = 'i1'")
            #expect(v6 == 0)
            try db.execute(sql: "UPDATE items SET status = 'active' WHERE id = 'i1'")
            try db.execute(sql: "INSERT OR REPLACE INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at) VALUES ('i1', 'task', 'todo', 'active', 'Otra cosa', 'UTC', 0.5, datetime('now'), datetime('now'), datetime('now'), datetime('now'))")
            let v7 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items WHERE item_id = 'i1'")
            #expect(v7 == 1)
            try db.execute(sql: "DELETE FROM items WHERE id = 'i1'")
            let v8 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_items")
            #expect(v8 == 0)
        }
    }

    @Test func aV8DatabaseMigratesToV9WithItsItemsAndNoIndexVersion() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let paths = try makePaths(temp)
        do {
            let pool = try DatabasePool(path: paths.database.path)
            try Migrations.make().migrate(pool, upTo: "v8")
            try pool.write { db in
                try self.insertItem(db, id: "i1", title: "Daily standup")
                try db.execute(sql: "INSERT INTO item_aliases (item_id, normalised, title) VALUES ('i1', 'standup', 'Standup')")
            }
            try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        }
        let db = try #require(opened(try StorageDatabase.open(paths: paths)))
        try db.pool.read { db in
            let v9 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items")
            #expect(v9 == 1)
            let v10 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_meta WHERE key = 'index_version'")
            #expect(v10 == 0)
        }
    }
}
