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
        return migrator
    }
}
