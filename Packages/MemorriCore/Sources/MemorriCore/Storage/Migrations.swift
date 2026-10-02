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
        // Spec 005: items made of sightings, with per-field observations, locks, aliases, an operation log and a title embedding cache.
        // Only `sightings` belongs to a picture (cascade); the rest is the user's list of items and is swept after cleanups.
        migrator.registerMigration("v5") { db in
            try db.alter(table: "image_analysis") { t in
                t.add(column: "reconciled_at", .datetime)
                t.add(column: "reconcile_error", .text)
            }
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull().check(sql: "kind IN ('appointment', 'task', 'reminder', 'deadline')")
                t.column("family", .text).notNull().check(sql: "family IN ('event', 'todo')")
                t.column("status", .text).notNull().check(sql: "status IN ('active', 'dismissed', 'merged')")
                t.column("merged_into", .text).references("items")
                t.column("context_id", .text).references("contexts", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("all_day", .integer).notNull().defaults(to: 0)
                t.column("start_at", .datetime)
                t.column("end_at", .datetime)
                t.column("due_at", .datetime)
                t.column("remind_at", .datetime)
                t.column("timezone", .text).notNull()
                t.column("day_key", .text)
                t.column("people_json", .text).notNull().defaults(to: "[]")
                t.column("place", .text)
                t.column("notes", .text)
                t.column("confidence", .double).notNull()
                t.column("user_touched", .integer).notNull().defaults(to: 0)
                t.column("first_seen", .datetime).notNull()
                t.column("last_seen", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "items_candidates", on: "items", columns: ["context_id", "family", "day_key"])
            try db.create(index: "items_status", on: "items", columns: ["status"])
            try db.create(table: "sightings") { t in
                t.primaryKey("id", .text)
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("finding_id", .text).notNull()
                t.column("captured_at", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("cited_lines_json", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("decision_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "sightings_item_id", on: "sightings", columns: ["item_id"])
            try db.create(index: "sightings_image_id", on: "sightings", columns: ["image_id"])
            try db.create(table: "observations") { t in
                t.primaryKey("id", .text)
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("sighting_id", .text).references("sightings", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("value_json", .text).notNull()
                t.column("source", .text).notNull().check(sql: "source IN ('read', 'inferred', 'user')")
                t.column("confidence", .double).notNull()
                t.column("observed_at", .datetime).notNull()
            }
            try db.create(index: "observations_item_field", on: "observations", columns: ["item_id", "field"])
            try db.create(table: "field_locks") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("observation_id", .text).notNull().references("observations", onDelete: .cascade)
                t.column("locked_at", .datetime).notNull()
                t.primaryKey(["item_id", "field"])
            }
            try db.create(table: "item_aliases") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("normalised", .text).notNull()
                t.column("title", .text).notNull()
                t.primaryKey(["item_id", "normalised"])
            }
            try db.create(table: "keep_apart") { t in
                t.column("item_a", .text).notNull().references("items", onDelete: .cascade)
                t.column("item_b", .text).notNull().references("items", onDelete: .cascade)
                t.column("op_id", .text).notNull()
                t.primaryKey(["item_a", "item_b"])
            }
            try db.create(table: "possible_duplicates") { t in
                t.column("item_a", .text).notNull().references("items", onDelete: .cascade)
                t.column("item_b", .text).notNull().references("items", onDelete: .cascade)
                t.column("scores_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["item_a", "item_b"])
            }
            try db.create(table: "reconcile_ops") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('auto_merge', 'merge', 'split', 'dismiss', 'restore', 'edit', 'unlock', 'context', 'different', 'undo')")
                t.column("by_user", .integer).notNull()
                t.column("item_ids_json", .text).notNull()
                t.column("moved_json", .text).notNull()
                t.column("before_json", .text).notNull()
                t.column("detail_json", .text).notNull()
                t.column("undone_by", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "reconcile_ops_created_at", on: "reconcile_ops", columns: ["created_at"])
            // The history of an item outlives it, so `item_id` is not a foreign key.
            try db.create(table: "reconcile_op_items") { t in
                t.column("op_id", .text).notNull().references("reconcile_ops", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.primaryKey(["op_id", "item_id"])
            }
            try db.create(index: "reconcile_op_items_item_id", on: "reconcile_op_items", columns: ["item_id"])
            try db.create(table: "title_embeddings") { t in
                t.column("normalised", .text).notNull()
                t.column("model", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["normalised", "model"])
            }
        }
        // Spec 006: evidence cut-outs that belong to an item (they outlive their capture), and the review state of an item. The
        // `approve` operation kind needs the CHECK of `reconcile_ops` changed, which SQLite only allows by building the table again.
        migrator.registerMigration("v6") { db in
            try db.alter(table: "items") { t in
                t.add(column: "needs_review", .integer).notNull().defaults(to: 0)
                t.add(column: "review_reasons_json", .text).notNull().defaults(to: "[]")
                t.add(column: "approved_at", .datetime)
                t.add(column: "approved_values_json", .text)
            }
            try db.create(index: "items_review", on: "items", columns: ["needs_review", "status"])
            try db.create(table: "evidence") { t in
                t.primaryKey("id", .text)
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("sighting_id", .text).references("sightings", onDelete: .setNull)
                t.column("image_id", .text).notNull()
                t.column("captured_at", .datetime).notNull()
                t.column("display_name", .text)
                t.column("title", .text).notNull()
                t.column("cited_lines_json", .text).notNull()
                t.column("region_json", .text).notNull()
                t.column("file_path", .text)
                t.column("reason", .text)
                t.column("bytes", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "evidence_item", on: "evidence", columns: ["item_id", "captured_at"])
            try db.create(index: "evidence_image", on: "evidence", columns: ["image_id"])
            try db.create(index: "evidence_sighting", on: "evidence", columns: ["sighting_id"], unique: true, condition: Column("sighting_id") != nil)

            try db.create(table: "reconcile_ops_v6") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('auto_merge', 'merge', 'split', 'dismiss', 'restore', 'edit', 'unlock', 'context', 'different', 'undo', 'approve')")
                t.column("by_user", .integer).notNull()
                t.column("item_ids_json", .text).notNull()
                t.column("moved_json", .text).notNull()
                t.column("before_json", .text).notNull()
                t.column("detail_json", .text).notNull()
                t.column("undone_by", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.execute(sql: "INSERT INTO reconcile_ops_v6 SELECT id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at FROM reconcile_ops")
            try db.drop(table: "reconcile_ops")
            try db.rename(table: "reconcile_ops_v6", to: "reconcile_ops")
            try db.create(index: "reconcile_ops_created_at", on: "reconcile_ops", columns: ["created_at"])
        }
        // Items that exist already get their review state once, from what is stored (it is kept up to date by every recompute after this).
        migrator.registerMigration("v6-review") { db in
            for id in try String.fetchAll(db, sql: "SELECT id FROM items WHERE status != 'merged'") { try ItemStore.refreshReview(db, itemID: id) }
        }
        // Cut-outs show the context around the cited lines from now on; the version says which shape a cut-out has, so older ones are made again.
        migrator.registerMigration("v7") { db in
            try db.alter(table: "evidence") { t in t.add(column: "geometry", .integer).notNull().defaults(to: 1) }
        }
        // Spec 011: a picture is read window by window. What each window was (kept as a row per picture and window), the window a finding was read
        // from, the clock used for relative dates, the window names that sightings and evidence carry, and a priority so a background re-read of the
        // library never runs before a new capture.
        migrator.registerMigration("v8") { db in
            try db.create(table: "window_readings") { t in
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("window_key", .text).notNull()
                t.column("app_name", .text)
                t.column("title", .text)
                t.column("frame_json", .text).notNull()
                t.column("visible_json", .text).notNull()
                t.column("visible_share", .double).notNull()
                t.column("relevant", .integer).notNull()
                t.column("kind", .text)
                t.column("confidence", .double).notNull()
                t.column("remote", .integer).notNull().defaults(to: 0)
                t.column("run_id", .text)
                t.column("prompt_version", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["image_id", "window_key"])
            }
            try db.alter(table: "findings") { t in t.add(column: "window_key", .text) }
            try db.alter(table: "image_analysis") { t in
                t.add(column: "reference_at", .datetime)
                t.add(column: "reference_source", .text)
                t.add(column: "windows_read", .integer).notNull().defaults(to: 1)
            }
            for table in ["sightings", "evidence"] {
                try db.alter(table: table) { t in
                    t.add(column: "window_app", .text)
                    t.add(column: "window_title", .text)
                }
            }
            try db.alter(table: "analysis_jobs") { t in t.add(column: "priority", .integer).notNull().defaults(to: 0) }
            try db.drop(index: "analysis_jobs_state_created_at")
            try db.create(index: "analysis_jobs_state_priority_created_at", on: "analysis_jobs", columns: ["state", "priority", "created_at"])
        }

        // Spec 007: the search indexes. Derived data (ADR 0023): item documents are replaced by triggers, capture documents are written with the
        // text and removed with the capture; `search_meta.index_version` tells the app whether a rebuild is due.
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_items USING fts5(
                    item_id UNINDEXED, title, aliases, notes, place, people,
                    tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4')
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_captures USING fts5(
                    image_id UNINDEXED, body,
                    tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4')
                """)
            try db.create(table: "search_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
            /// Replaces the item's row: delete it, then insert it again unless the item is merged. `id` is a trigger column reference.
            func document(_ id: String) -> String {
                """
                DELETE FROM search_items WHERE item_id = \(id);
                INSERT INTO search_items (item_id, title, aliases, notes, place, people)
                SELECT i.id, i.title,
                       COALESCE((SELECT group_concat(a.title, ' ') FROM item_aliases a WHERE a.item_id = i.id AND a.title != i.title), ''),
                       COALESCE(i.notes, ''), COALESCE(i.place, ''),
                       CASE WHEN json_valid(i.people_json) THEN COALESCE((SELECT group_concat(value, ' ') FROM json_each(i.people_json)), '') ELSE '' END
                FROM items i WHERE i.id = \(id) AND i.status != 'merged';
                """
            }
            try db.execute(sql: "CREATE TRIGGER search_items_after_insert AFTER INSERT ON items BEGIN \(document("new.id")) END")
            try db.execute(sql: """
                CREATE TRIGGER search_items_after_update AFTER UPDATE OF title, notes, place, people_json, status ON items
                BEGIN \(document("new.id")) END
                """)
            try db.execute(sql: "CREATE TRIGGER search_items_after_delete AFTER DELETE ON items BEGIN DELETE FROM search_items WHERE item_id = old.id; END")
            try db.execute(sql: "CREATE TRIGGER search_aliases_after_insert AFTER INSERT ON item_aliases BEGIN \(document("new.item_id")) END")
            try db.execute(sql: "CREATE TRIGGER search_aliases_after_update AFTER UPDATE ON item_aliases BEGIN \(document("new.item_id")) END")
            try db.execute(sql: "CREATE TRIGGER search_aliases_after_delete AFTER DELETE ON item_aliases BEGIN \(document("old.item_id")) END")
            try db.execute(sql: "CREATE TRIGGER search_captures_after_read_delete AFTER DELETE ON ocr_reads BEGIN DELETE FROM search_captures WHERE image_id = old.image_id; END")
        }

        // Spec 008: reprocessing trials (ADR 0025). A trial reads stored captures with another model into tables of its own; nothing of it is
        // read back by live analysis or by items. A trial job carries the trial it belongs to, and `apply_trial` joins the operation kinds.
        migrator.registerMigration("v10") { db in
            try db.create(table: "trials") { t in
                t.primaryKey("id", .text)
                t.column("model", .text).notNull()
                t.column("prompt_version", .text).notNull()
                t.column("think", .text).notNull()
                t.column("state", .text).notNull().check(sql: "state IN ('running', 'finished', 'cancelled')")
                t.column("created_at", .datetime).notNull()
                t.column("finished_at", .datetime)
            }
            try db.create(table: "trial_images") { t in
                t.column("trial_id", .text).notNull().references("trials", onDelete: .cascade)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("state", .text).notNull().check(sql: "state IN ('waiting', 'read', 'skipped', 'failed')")
                t.column("reason", .text)
                t.column("finding_count", .integer).notNull().defaults(to: 0)
                t.column("duration_ms", .integer)
                t.primaryKey(["trial_id", "image_id"])
            }
            try db.create(table: "trial_findings") { t in
                t.primaryKey("id", .text)
                t.column("trial_id", .text).notNull().references("trials", onDelete: .cascade)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("kind", .text).notNull()
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
                t.column("window_key", .text)
                t.column("window_app", .text)
                t.column("window_title", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "trial_findings_trial_image", on: "trial_findings", columns: ["trial_id", "image_id"])
            try db.alter(table: "analysis_jobs") { t in t.add(column: "trial_id", .text) }
            try db.create(index: "analysis_jobs_trial", on: "analysis_jobs", columns: ["trial_id"])

            try db.create(table: "reconcile_ops_v10") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('auto_merge', 'merge', 'split', 'dismiss', 'restore', 'edit', 'unlock', 'context', 'different', 'undo', 'approve', 'apply_trial')")
                t.column("by_user", .integer).notNull()
                t.column("item_ids_json", .text).notNull()
                t.column("moved_json", .text).notNull()
                t.column("before_json", .text).notNull()
                t.column("detail_json", .text).notNull()
                t.column("undone_by", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.execute(sql: "INSERT INTO reconcile_ops_v10 SELECT id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at FROM reconcile_ops")
            try db.drop(table: "reconcile_ops")
            try db.rename(table: "reconcile_ops_v10", to: "reconcile_ops")
            try db.create(index: "reconcile_ops_created_at", on: "reconcile_ops", columns: ["created_at"])
        }
        // Spec 009: the entries Memorri wrote to Calendar and Reminders (ADR 0026) and the runs that wrote them.
        migrator.registerMigration("v11") { db in
            try db.create(table: "sync_links") { t in
                t.primaryKey("item_id", .text).references("items", onDelete: .cascade)
                t.column("kind", .text).notNull().check(sql: "kind IN ('event', 'reminder')")
                t.column("ek_id", .text).notNull()
                t.column("container_id", .text).notNull()
                t.column("hash", .text).notNull()
                t.column("hash_version", .integer).notNull()
                t.column("fields_json", .text).notNull()
                t.column("state", .text).notNull().check(sql: "state IN ('synced', 'completed', 'removed_by_user', 'removed', 'failed')")
                t.column("failure", .text)
                t.column("synced_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "sync_links_ek_id", on: "sync_links", columns: ["ek_id"])
            try db.create(table: "sync_runs") { t in
                t.primaryKey("id", .text)
                t.column("started_at", .datetime).notNull()
                t.column("finished_at", .datetime).notNull()
                t.column("preview", .integer).notNull()
                t.column("created", .integer).notNull().defaults(to: 0)
                t.column("updated", .integer).notNull().defaults(to: 0)
                t.column("removed", .integer).notNull().defaults(to: 0)
                t.column("adopted", .integer).notNull().defaults(to: 0)
                t.column("skipped", .integer).notNull().defaults(to: 0)
                t.column("failed", .integer).notNull().defaults(to: 0)
                t.column("detail_json", .text).notNull().defaults(to: "[]")
            }
        }
        // Spec 010: what calendar views showed, the captures that covered an item without showing it, and the user's `Still happening`.
        migrator.registerMigration("v12") { db in
            try db.create(table: "calendar_coverage") { t in
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("window_key", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull().check(sql: "kind IN ('calendar_week', 'calendar_day')")
                t.column("spans_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["image_id", "window_key"])
            }
            try db.create(table: "cancel_absences") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("image_id", .text).notNull().references("capture_images", onDelete: .cascade)
                t.column("event_id", .text).notNull()
                t.column("captured_at", .datetime).notNull()
                t.primaryKey(["item_id", "image_id"])
            }
            try db.create(index: "cancel_absences_item", on: "cancel_absences", columns: ["item_id", "captured_at"])
            try db.alter(table: "items") { t in t.add(column: "cancel_cleared_at", .datetime) }

            // `Still happening` is an operation of its own (undoable), so the log accepts one more kind.
            try db.create(table: "reconcile_ops_v12") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('auto_merge', 'merge', 'split', 'dismiss', 'restore', 'edit', 'unlock', 'context', 'different', 'undo', 'approve', 'apply_trial', 'still_happening')")
                t.column("by_user", .integer).notNull()
                t.column("item_ids_json", .text).notNull()
                t.column("moved_json", .text).notNull()
                t.column("before_json", .text).notNull()
                t.column("detail_json", .text).notNull()
                t.column("undone_by", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.execute(sql: "INSERT INTO reconcile_ops_v12 SELECT id, kind, by_user, item_ids_json, moved_json, before_json, detail_json, undone_by, created_at FROM reconcile_ops")
            try db.drop(table: "reconcile_ops")
            try db.rename(table: "reconcile_ops_v12", to: "reconcile_ops")
            try db.create(index: "reconcile_ops_created_at", on: "reconcile_ops", columns: ["created_at"])
        }
        return migrator
    }
}
