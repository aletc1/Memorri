# Implementation Plan: Find anything Memorri has seen

**Branch**: `007-search` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/007-search/spec.md`

## Summary

Two full-text indexes live in the same SQLite database as the data they describe: one document per item (title, aliases, notes, place, people) and one document per capture (its recognised text). Both are derived: item documents are kept by database triggers in the same transaction as every change to items and aliases, capture documents are written in the transaction that stores a capture's text and removed when the capture goes. A pure query parser turns what the user typed into a safe match expression and filters; a core `SearchService` runs it and returns items first, then captures with their best matching lines and the window they were in. The app adds a floating quick-search panel (menu item, global shortcut, Settings recorder), a search field in the Items window, and a capture viewer for capture results. A launch check rebuilds the indexes in the background when they are missing or outdated (ADR 0023).

## Technical Context

**Language/Version**: Swift 6, SwiftUI plus AppKit, macOS 26+ (XcodeGen project).

**Primary Dependencies**: GRDB.swift (system SQLite 3.54, FTS5 compiled in; checked with `sqlite_compileoption_used('ENABLE_FTS5')` and spiked in task T001), KeyboardShortcuts (already used for capture).

**Storage**: the existing `memorri.sqlite`; migration `v9` adds `search_items`, `search_captures` (FTS5, `unicode61 remove_diacritics 2`, prefix indexes) and `search_meta`.

**Testing**: Swift Testing in `Packages/MemorriCore/Tests/MemorriCoreTests`; scale test for SC-001 and SC-006; no prompt or model change, so the eval harness is not affected (constitution VI is met by tests).

**Target Platform**: macOS 26+.

**Project Type**: desktop app (menu-bar) with a core package.

**Performance Goals**: results under 200 ms after the last key on 5,000 items and 200,000 lines; first results of an opening panel under 300 ms; at most 5% added to analysing a capture.

**Constraints**: local only; no query, result or snippet in logs; the index is rebuildable from stored data; a bad query never fails.

**Scale/Scope**: thousands of items, hundreds of captures with up to a few thousand lines each.

## Constitution Check

| Principle | Status |
|---|---|
| I Local-first and private | Pass: no network; search logs only counts and durations (FR-014, SC-007); Delete everything removes the index with the library (FR-015). |
| II Every item carries evidence | Pass: search shows where a result matched and opens the evidence view for captures. |
| III Idempotent, no duplicates | Pass: merged items are never listed on their own (FR-008); a rebuild equals the incremental index (SC-005). |
| IV The user wins | Pass: dismissed items stay hidden unless asked; search only reads items. |
| V Raw data under user control | Pass: OCR text is searchable only while kept; retention removes its text from the index. |
| VI Test-first core | Pass: tasks write tests first; the parser, ranking, filters, freshness and rebuild are core code. |
| VII Incremental, always runnable | Pass: US1 (items) ships alone; captures, filters and the shortcut follow. |
| VIII Decisions recorded | ADR 0023 (Proposed). |

No violations; the post-design check is the same.

## Project Structure

### Documentation (this feature)

```text
specs/007-search/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── core-interfaces.md
│   └── ui-contract.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/MemorriCore/Sources/MemorriCore/Search/
├── SearchQuery.swift        # parse typed text into words, phrases, exclusions; the match expression; filters
├── SearchIndex.swift        # trigger SQL, capture documents, rebuild, state (ready / preparing), version
├── SearchService.swift      # item results, capture results, ranking, paging
├── SearchResults.swift      # result types and the marked text
└── SearchText.swift         # folding (case, accents) and word splitting shared with line matching
Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift   # v9
Packages/MemorriCore/Sources/MemorriCore/Recognition/OCRStore.swift # writes the capture document with the lines
App/Search/
├── SearchPanelController.swift   # floating panel, shortcut, focus, Escape
├── SearchPanelView.swift         # field, filters, results
├── SearchViewModel.swift         # query, filters, task per keystroke, state
└── CaptureViewer.swift           # whole capture with matching lines, or text when the picture is gone
App/Adapters/ShortcutAdapter.swift  # second shortcut name `search`, validated against capture
App/Windows/ItemsView.swift, ItemsViewModel.swift  # search field and open-item entry point
App/MenuContent.swift, WindowCoordinator.swift     # menu item opens the panel; the placeholder window goes
Packages/MemorriCore/Tests/MemorriCoreTests/Search*Tests.swift
```

**Structure Decision**: one new `Search` folder in the core package and one in the app, as for evidence and windows; no new target.

## Complexity Tracking

None to justify.
