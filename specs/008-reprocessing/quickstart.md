# Quickstart: reprocessing (spec 008)

1. `swift test --package-path Packages/MemorriCore --filter Trial` (store, runner, comparison, apply, undo, isolation).
2. Run with an isolated home (no copy of the app running on real data) and `--ingest-case` of golden cases; in Settings > Analysis start a trial with another installed model; watch progress; the Items window does not change.
3. Open the comparison, apply one difference, see the item change and its history; Undo; apply again; History lists both.
4. Cancel a trial, quit and reopen: it resumes, no capture read twice.
