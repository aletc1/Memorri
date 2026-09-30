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
        return migrator
    }
}
