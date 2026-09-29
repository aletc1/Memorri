# 3. SQLite through GRDB.swift

- Status: Accepted
- Date: 2026-09-29

## Context and problem
We need a local index with partial entities, migrations, live UI updates and full-text search.

## Decision
Use SQLite via GRDB.swift: versioned migrations, FTS5 for search, ValueObservation for UI. Entities are resolved from per-field observations so they can be filled in progressively. Database lives in ~/Library/Application Support/Memorri/ with image blobs beside it, excluded from Time Machine.

## Consequences
Adds one Swift dependency. Schema changes require a migration.
