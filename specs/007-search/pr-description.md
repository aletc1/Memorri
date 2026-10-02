## What changed and why

Memorri keeps items, aliases and the recognised text of every capture, but there was no way to find any of it by a few words. This adds search (spec 007, ADR 0023).

- **Quick-search panel**: opens from the menu (`Search…`) and a global shortcut (default Control-Option-Command-F, recordable in Settings, checked against the capture shortcut), floats over any app, takes the keyboard, closes on Escape. Items first, then captures; matching words are marked.
- **Items**: title, aliases, notes, place and people; case and accents ignored, all words required, the last one matched by its beginning, quoted phrases and `-excluded` words. Return opens the item in the Items window.
- **Captures**: the text of a capture is searched as a whole (words may be on different lines); a result shows when, which display, which window, and up to three matching lines. It opens a capture window with the lines outlined, or the text alone when the picture is gone.
- **Filters**: kind, context and date range (presets or a custom range), dismissed on or off; the Items window has a search field with the same rules.
- **Index**: two derived FTS5 tables in the library database (migration `v9`). Item rows are kept by triggers, capture documents are written with the text and removed with the capture, so results follow every edit, merge, split, undo, retention and Delete everything. A missing or outdated index is rebuilt in the background while the panel says it is being prepared.

Spec: `specs/007-search/`. ADR: `docs/architecture/decisions/0023-search-index-in-the-library-database.md`. Also: the picture view of spec 006 is now shared by the evidence sheet and the capture window; a debug switch `--open-search <text>`.

## How it was verified

- `swift test --package-path Packages/MemorriCore`: 1,304 tests pass. Debug and Release builds succeed; the Release binary has no ingest switches.
- Scale (release, 5,000 items and 200,000 lines): typical query 0.9 ms, common words with a page of captures 24 ms, rare word 18 ms (limit 200 ms); debug builds are within a few ms of these. A full rebuild equals the trigger-kept index. Search logs only counts (tested against the process log).
- Run in the app on synthetic cases with an isolated home: the index is built at launch; the shortcut opens the panel over another app and the typed words reach it; an item result shows marked words, a capture result shows the window name and the marked line; Return opens the item selected in the Items window and the capture window with its text scrolled to the match; the menu shows the shortcut.
- Branch diff matched against strings of the real database (count-only): one project name from a screenshot had slipped into tests and the spec and was replaced in every commit before pushing; nothing else.

## For the reviewer

- `Storage/Migrations.swift` `v9` (triggers) and `Search/SearchIndex.swift` (capture documents, probe, rebuild).
- `Search/SearchQuery.swift` (nothing typed reaches FTS unquoted) and `Search/SearchService.swift` (ranking, filters, the SQL line filter).
- `App/Search/` (the panel is a non-activating `NSPanel`).

## Known gaps

- VoiceOver, the panel over a full-screen app and a stopwatch timing of "find an item in under 10 seconds" were not checked by hand.
- No typo tolerance or stemming (out of scope); ranking of items is bm25 with fixed field weights, captures are newest first.
- The first launch with the new build writes `KeyboardShortcuts_search` (the default) into the preferences, as for the capture shortcut.
