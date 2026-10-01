import GRDB

enum Migrations {
    static func make() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "capture_events") { t in
                t.primaryKey("id", .text)
                t.column("captured_at", .datetime).notNull()
                t.column("trigger", .text).notNull().check(sql: "trigger IN ('menu', 'shortcut')")
                t.column("status", .text).notNull().check(sql: "status IN ('complete', 'partial', 'failed')")
                t.column("failure_reason", .text)
                t.column("display_count", .integer).notNull()
            }
            try db.create(table: "capture_images") { t in
                t.primaryKey("id", .text)
                t.column("event_id", .text).notNull().references("capture_events", onDelete: .cascade)
                t.column("display_id", .integer).notNull()
                t.column("display_name", .text)
                t.column("pixel_width", .integer).notNull()
                t.column("pixel_height", .integer).notNull()
                t.column("scale", .double).notNull()
                t.column("full_path", .text).notNull()
                t.column("model_path", .text).notNull()
                t.column("model_width", .integer).notNull()
                t.column("model_height", .integer).notNull()
                t.column("full_bytes", .integer).notNull()
                t.column("model_bytes", .integer).notNull()
                t.column("missing", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "capture_events_captured_at", on: "capture_events", columns: ["captured_at"])
            try db.create(index: "capture_images_event_id", on: "capture_images", columns: ["event_id"])
        }
        // Spec 003: the analysis queue and the record of every model attempt (ADR 0012).
        migrator.registerMigration("v2") { db in
            try db.create(table: "analysis_jobs") { t in
                t.primaryKey("id", .text)
                // No CHECK on kind: a later spec can add a kind without rebuilding the table.
                t.column("kind", .text).notNull()
                // No foreign key: a queued job must outlive its picture and fail with a clear reason.
                t.column("image_id", .text)
                t.column("state", .text).notNull().check(sql: "state IN ('waiting', 'running', 'finished', 'failed')")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("not_before", .datetime)
                t.column("failure_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "model_runs") { t in
                t.primaryKey("id", .text)
                t.column("job_id", .text).notNull()     // no foreign key: clearing jobs keeps runs that belong to captures
                // A capture's runs are deleted with it in every kind of cleanup.
                t.column("image_id", .text).references("capture_images", onDelete: .cascade)
                t.column("attempt", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("think", .text).notNull()
                t.column("temperature", .double).notNull()
                t.column("image_long_edge", .integer).notNull()
                t.column("prompt_version", .text).notNull()
                t.column("schema_version", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("outcome", .text).notNull().check(sql: "outcome IN ('success', 'failed')")
                t.column("failure_reason", .text)
                t.column("request_json", .text).notNull()
                t.column("raw_answer", .text)
            }
            try db.create(index: "analysis_jobs_state_created_at", on: "analysis_jobs", columns: ["state", "created_at"])
            try db.create(index: "model_runs_image_id", on: "model_runs", columns: ["image_id"])
            try db.create(index: "model_runs_job_id", on: "model_runs", columns: ["job_id"])
        }
        // Spec 004: contexts, window titles, recognised text, analysis results, tags and findings (ADR 0014, 0016).
        // Everything that belongs to one picture references capture_images with ON DELETE CASCADE, so every kind of
        // cleanup removes it together with the capture. Only contexts and their hints belong to the user.
        migrator.registerMigration("v3") { db in
            try db.create(table: "contexts") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("timezone", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.execute(sql: "CREATE UNIQUE INDEX contexts_name_nocase ON contexts (lower(name))")
            try db.create(table: "context_hints") { t in
                t.primaryKey("id", .text)
                t.column("context_id", .text).notNull().references("contexts", onDelete: .cascade)
                t.column("kind", .text).notNull().check(sql: "kind IN ('window_title', 'app', 'domain', 'keyword')")
                t.column("value", .text).notNull()
            }
            try db.create(index: "context_hints_context_id", on: "context_hints", columns: ["context_id"])

            try db.create(table: "capture_windows") { t in
                t.primaryKey("id", .text)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("z", .integer).notNull()
                t.column("app_name", .text)
                t.column("bundle_id", .text)
                t.column("title", .text)
                t.column("x", .integer).notNull()
                t.column("y", .integer).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
            }
            try db.create(index: "capture_windows_image_id", on: "capture_windows", columns: ["image_id"])

            try db.create(table: "ocr_reads") { t in
                t.primaryKey("image_id", .text).references("capture_images", onDelete: .cascade)
                t.column("read_at", .datetime).notNull()
                t.column("line_count", .integer).notNull()
                t.column("recogniser", .text).notNull()
                t.column("duration_ms", .integer).notNull()
            }
            try db.create(table: "ocr_lines") { t in
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("n", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("x", .integer).notNull()
                t.column("y", .integer).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("confidence", .double).notNull()
                t.primaryKey(["image_id", "n"])
            }

            try db.create(table: "image_analysis") { t in
                t.primaryKey("image_id", .text).references("capture_images", onDelete: .cascade)
                t.column("screen_kind", .text).notNull().check(sql: "screen_kind IN ('calendar_month', 'calendar_week', 'calendar_day', 'email', 'chat', 'document', 'other')")
                t.column("kind_confidence", .double).notNull()
                t.column("classify_version", .text).notNull()
                t.column("prompt_version", .text).notNull()
                t.column("schema_version", .text).notNull()
                t.column("model", .text).notNull()
                t.column("picture_long_edge", .integer).notNull()
                t.column("timezone", .text).notNull()
                t.column("timezone_source", .text).notNull().check(sql: "timezone_source IN ('context', 'mac', 'invalid-context-zone')")
                t.column("finding_count", .integer).notNull()
                t.column("line_cap_applied", .integer).notNull().defaults(to: 0)
                t.column("discarded_json", .text).notNull().defaults(to: "[]")
                t.column("extract_run_id", .text)
                t.column("analysed_at", .datetime).notNull()
            }
            try db.create(table: "image_context") { t in
                t.primaryKey("image_id", .text).references("capture_images", onDelete: .cascade)
                t.column("context_id", .text).references("contexts", onDelete: .setNull)
                t.column("source", .text).notNull().check(sql: "source IN ('auto', 'user', 'none')")
                t.column("score", .double).notNull()
                t.column("matched_json", .text).notNull().defaults(to: "[]")
                t.column("runner_up_json", .text)
                t.column("decided_at", .datetime).notNull()
            }
            try db.create(table: "capture_tags") { t in
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                // No CHECK on key: the list of keys is validated in code so a new key needs no table rebuild.
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("source", .text).notNull()
                t.primaryKey(["image_id", "key", "value"])
            }
            try db.create(table: "findings") { t in
                t.primaryKey("id", .text)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("run_id", .text)
                t.column("kind", .text).notNull().check(sql: "kind IN ('appointment', 'task', 'reminder', 'deadline')")
                t.column("title", .text).notNull()
                t.column("all_day", .integer).notNull().defaults(to: 0)
                t.column("start_at", .datetime)
                t.column("end_at", .datetime)
                t.column("due_at", .datetime)
                t.column("remind_at", .datetime)
                t.column("timezone", .text).notNull()
                t.column("people_json", .text).notNull().defaults(to: "[]")
                t.column("place", .text)
                t.column("notes", .text)
                t.column("cited_lines_json", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("provenance_json", .text).notNull()
                t.column("unresolved_json", .text).notNull().defaults(to: "{}")
                t.column("tags_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "findings_image_id", on: "findings", columns: ["image_id"])
            try db.create(index: "findings_start_at", on: "findings", columns: ["start_at"])

            try db.execute(sql: "ALTER TABLE model_runs ADD COLUMN step TEXT NOT NULL DEFAULT 'test'")
        }
        // The stack order of the windows of a picture (0 in front), so a window drawn over a calendar can be told from one behind it.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE capture_windows ADD COLUMN stack INTEGER")
        }
        return migrator
    }
}
