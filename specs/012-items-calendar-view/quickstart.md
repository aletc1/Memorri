# Quickstart: items calendar view (spec 012)

1. `swift test --package-path Packages/MemorriCore --filter ItemCalendar` (pinning, grid, order, undated, filters).
2. Build and run with an isolated home, ingest cases with dated items (`--ingest-case`), open the Items window: header is one row at the smallest width; switch to Calendar; items are on their days; Next, Previous, Today; click a chip, detail opens; switch back, selection kept.
3. Approve, Dismiss, Undo from the icons; the calendar follows. Quit and reopen: same view and month.
