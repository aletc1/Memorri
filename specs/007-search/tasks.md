---

description: "Task list for spec 007: search"
---

# Tasks: Find anything Memorri has seen

**Input**: Design documents from `/specs/007-search/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (all present). Specs 005, 006 and 011 are merged to `main`.

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. Search changes no prompt or model, so the eval harness is not affected.

**Organization**: Grouped by user story in priority order: US1 items (P1), US2 captures (P2), US3 filters (P2), US4 reach and freshness (P3). Each story leaves the app runnable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US4 as in the spec
- Commands assume the repository root as the working directory.
- **Privacy**: tests use synthetic titles and drawn text only. The user's real database is opened only where a task says so, with their go-ahead, counts only. No query, result or snippet is ever logged. Isolated app runs do not isolate preferences: delete any key a run set (`defaults delete com.aletc1.memorri <key>`).
- Tasks that edit `Tests/MemorriCoreTests/Fakes.swift` are not marked parallel.

## Phase 1: Setup

**Purpose**: Prove FTS5 works through GRDB here, then the tables every story needs.

- [X] T001 Spike (throwaway test, not committed): in a scratch `Packages/MemorriCore/Tests/MemorriCoreTests/ZzFTSSpikeTests.swift` open a `StorageDatabase`, create an FTS5 table with `tokenize = 'unicode61 remove_diacritics 2'` and `prefix = '2 3 4'`, insert `Café - Pruebas`, and check that `MATCH '"cafe" "pru"*'` finds it, `bm25()` ranks, and a trigger that deletes then inserts survives `INSERT OR REPLACE`; record the result in `research.md` under R1 ("Checked") and delete the scratch file
- [X] T002 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v9"` per `data-model.md`: FTS5 tables `search_items` (columns `item_id` unindexed, `title`, `aliases`, `notes`, `place`, `people`), `search_captures` (`image_id` unindexed, `body`) and `search_meta(key TEXT PRIMARY KEY, value TEXT)`; the triggers named in `data-model.md` exist (`items` insert, update of the searchable columns and status, delete; `item_aliases` insert, update, delete; `ocr_reads` delete); a database migrated from `v8` with items and aliases already in it opens, and `search_meta` has no `index_version`
- [X] T003 Implement migration `"v9"` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift` per `data-model.md` (the item document is built by one SQL expression shared by every trigger: delete the item's row, then insert it unless the item is `merged`; people by `json_each`, aliases by `group_concat` over the titles other than the item's own); the previous task's tests pass

**Checkpoint**: tests pass; `swift test --package-path Packages/MemorriCore` is green.

---

## Phase 2: Foundational

**Purpose**: Text folding and the query parser, used by every story. Blocks all stories.

- [X] T004 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchTextTests.swift` for `SearchText.fold` (lower case, accents removed: `Café` and `CAFÉ` give `cafe`) and `SearchText.words` (split on anything that is not a letter or digit; keeps digits, `2291`), and for `SearchText.marks(of: terms, in: text)` (ranges of the words that match a query word, the last word by its beginning, the rest whole, accent- and case-blind; ranges are in the original text)
- [X] T005 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchQueryTests.swift` per `contracts/core-interfaces.md`: `terms` of `cafe pru` is two words; `"daily standup"` is a phrase; `-budget` is an exclusion; stray `"`, `*`, `:`, `(`, `)`, `-` alone and `NEAR` never reach the expression unquoted; `isSearchable` is false for an empty text, one letter, only punctuation and only exclusions; `matchExpression` quotes every term, puts the prefix star on the last positive word only, joins with `AND` and exclusions with `NOT`, and is nil when not searchable; a text of 2,000 characters does not fail
- [X] T006 Implement `SearchText` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchText.swift` and `SearchQuery` (parse, `isSearchable`, `matchExpression`) in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchQuery.swift` with the result types of `contracts/core-interfaces.md` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchResults.swift`; the two previous tasks' tests pass

**Checkpoint**: tests pass.

---

## Phase 3: User Story 1 - Type a few words, get the item (Priority: P1)

**Goal**: Matching items, best first, from a panel opened by the menu; Return opens the item.

**Independent Test**: A library of items; part of a title, an alias, notes or place find the item, in any case and accent; Return opens it in the Items window.

- [X] T007 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchItemsTests.swift` (uses `ReconcileFixture`): `SearchService.search` finds an item by title (`cafe pru` finds `Café - Pruebas`), by notes, place and people, by an alias after a second sighting under another title, with the field named in `matchedIn` (`alias` for the alias, `title` first when both match); all words are required; the last word matches by its beginning; a quoted phrase must be adjacent; an excluded word removes the item; a title match ranks above a notes match; ties are newest `last_seen` first; `moreItems` is true past the limit and `itemOffset` pages; the title and snippet carry marks; a query that is not searchable returns no results without throwing; every word of every title, notes, place, people and alias in a seeded library finds its item (SC-002); a rare word ranks its item above items that match only a very common word
- [X] T008 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchFreshnessTests.swift` that, for items, a search shows the new state right after each of: the reconciler creating an item and joining a sighting, `ItemOperations.edit` of title, notes, place and people (the old title still finds the item through its alias when it became one), lock, approve, dismiss (hidden by default, found with `includeDismissed` and `status == .dismissed`), restore, merge (only the kept item is found, once, for either title), undo of the merge (two items again), split, and the sweep after retention removing an untouched item (not found) while an edited one stays; no operation leaves a duplicate or stale row (count of `search_items` rows equals the count of non-merged items after each step)
- [X] T009 [US1] Implement `SearchService.search` for items and `itemIDs` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchService.swift` per R2, R5 and R6 (one FTS query joined to `items`, bm25 with weights title 10, aliases 6, notes, place and people 2, then `last_seen` descending; marked title and snippet through `SearchText.marks`; the field of the best match from per-column checks); tests of T007 and T008 pass
- [X] T010 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchPanelModelTests.swift` for a pure `SearchPanelModel` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchPanelModel.swift`: row text for an item hit (`Appointment, <title>, <date>, matched in alias`), the empty text (`Nothing found`, naming the active filters and offering to clear them when any are on), the short text (`Type at least two letters`), keyboard movement through rows (down from the last row stays, up from the first stays, Return on a row gives its target), and `Show more` rows; no UI types
- [X] T011 [US1] Implement `SearchPanelModel` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchPanelModel.swift`; the previous task's tests pass
- [X] T012 [US1] Add `App/Search/SearchViewModel.swift` (query text, a task per change that cancels the previous one so results are never mixed, state, results) and `App/Search/SearchPanelView.swift` (field with focus, results list, rows from `SearchPanelModel`, accessibility labels), and `App/Search/SearchPanelController.swift` (floating `NSPanel` centred on the display with the pointer, takes keys, closes on Escape and on losing key status, focuses itself if already open) per `contracts/ui-contract.md`; own it in `App/AppEnvironment.swift`
- [X] T013 [US1] Replace the placeholder: in `App/MenuContent.swift` the `Search` item becomes `Search…` and opens the panel; remove `.search` from `WindowID` in `App/Windows/WindowCoordinator.swift` and the placeholder view it used in `App/Windows/PlaceholderView.swift` if nothing else uses it
- [X] T014 [US1] Add `showItem(id:)` to the environment (`App/AppEnvironment.swift`) and `ItemsViewModel` (`App/Windows/ItemsViewModel.swift`): opens the Items window with the scope and filters that list the item (dismissed turns `showDismissed` on) and the item selected; Return or a click on an item result calls it and closes the panel; extend `Packages/MemorriCore/Tests/MemorriCoreTests/ItemListModelTests.swift` with the pure part (the filter that shows a given item) written first

**Checkpoint**: tests pass; Debug build; the panel finds items from the menu and Return opens the item.

---

## Phase 4: User Story 2 - Find the capture a line of text came from (Priority: P2)

**Goal**: Captures whose text matched, after the items, with the matching lines and the window; open one to see it.

**Independent Test**: A capture with a word that made no item is listed with its time, window and line; opening it shows the picture with the line outlined, or the text when the picture is gone.

- [X] T015 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchCapturesTests.swift` (extend `EvidenceFixture` where it helps): `OCRStore.save` writes one `search_captures` row per capture and writing again replaces it; deleting the capture (`CaptureStore.deleteEvents`) and `CleanupService.delete(olderThanDays:)` (also `nil` for everything) leave no row; a capture is found when all the words are in it on different lines; a result lists at most three lines with the most query words, marked, in reading order; the window is the application and title whose visible part holds the line's centre (from `window_readings`), nil without readings; captures come newest first after the items; `moreCaptures` and `captureOffset` page; a capture with no text has no row; the same word in two captures gives two results and the one item they made is listed once above; `waitingToBeAnalysed` counts the captures with a stored picture and no read text (and is 0 when none)
- [X] T016 [US2] Implement the capture document and its removal: `SearchIndex.writeCapture(_:imageID:lines:)` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchIndex.swift` called from `OCRStore.save` in `Packages/MemorriCore/Sources/MemorriCore/Recognition/OCRStore.swift` inside its transaction, and capture results, matching lines and the window in `SearchService.search` and `SearchService.lines(imageID:matching:)` per R3 and R4; the previous task's tests pass
- [X] T017 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchPanelModelTests.swift` (extend) for capture rows (`Capture, <time>, <display>, <window>, <first line>`) and for the capture viewer's text model in `Packages/MemorriCore/Sources/MemorriCore/Search/CaptureViewerModel.swift` (the matching lines marked; `The capture is no longer stored.` when the picture is gone; the lines still listed), then implement them
- [X] T018 [US2] Move the whole-capture view of spec 006 (`WholeCaptureSheet` in `App/Windows/EvidenceViews.swift`) into a shared `App/Search/CaptureViewer.swift` that takes an image id and the lines to outline (`EvidenceStore.capture(imageID:)`), keep the evidence card's use of it working, add a resizable `capture` window to `WindowID`, and make a capture result open it (Return or a click)

**Checkpoint**: tests pass; Debug build; a capture result opens its viewer.

---

## Phase 5: User Story 3 - Narrow by kind, context and date (Priority: P2)

**Goal**: Kind, context and date range filters in the panel, and a search field in the Items window.

**Independent Test**: Items of three kinds in two contexts over two months; each filter alone and together shrinks the results exactly; clearing restores them.

- [X] T019 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchFilterTests.swift` per R7 and the acceptance scenarios: kinds (appointments; tasks include deadlines; reminders; captures only hides items and skips the item query; several kinds combine), context (one, none, any; captures use the context of their image), dates (an event by `start_at`, a to-do by `due_at` then `start_at`, a capture by capture time; an item with no date is out of a range and in when there is none; both ends inclusive), `includeDismissed`, all together, and `itemIDs` honouring the same filters
- [X] T020 [US3] Implement the filters in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchService.swift`; the previous task's tests pass
- [X] T021 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchPanelModelTests.swift` (extend) for filter text (`Kind: Tasks`, `Context: <name>` or `No context`, `Dates: 1 Oct – 31 Oct`), the active-filter list, `Clear filters`, and the empty text naming the filters, then implement it in `SearchPanelModel`
- [X] T022 [US3] Add the filter controls (`Kind`, `Context`, `Date` menu buttons, `Dismissed` toggle, each active one with an `x`, `Clear filters`) to `App/Search/SearchPanelView.swift` and `App/Search/SearchViewModel.swift`; contexts come from `ContextStore`
- [X] T023 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemListModelTests.swift` (extend) for restricting the visible rows to ranked matching ids (`ItemListModel.restrict(rows, to: ids)` keeps the order of `ids`, drops the rest, empty text restores), implement it, and add the search field above the list in `App/Windows/ItemsView.swift` driven by `ItemsViewModel.searchText` (uses `SearchService.itemIDs` with the window's kind, context and dismissed filters)

**Checkpoint**: tests pass; Debug build; filters work in the panel and the Items window field narrows the list.

---

## Phase 6: User Story 4 - Reach it from anywhere, and keep it in step (Priority: P3)

**Goal**: A configurable global shortcut, a rebuildable index with a "preparing" state, and results that follow retention and Delete everything.

**Independent Test**: The shortcut opens the panel over another app and Escape closes it; after analysing, editing, merging, dismissing and deleting captures, a search shows the new state; a missing index is rebuilt and gives the same results.

- [X] T024 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchIndexTests.swift`: `state()` is `preparing` for a library with no `index_version`, `prepare` rebuilds in batches of 100 pictures reporting progress and sets `index_version`, a second `prepare` does nothing, an outdated version rebuilds, a row count that differs from the items that should be indexed rebuilds, a write during the rebuild (a new item, a new capture) is kept, `rebuild()` equals the trigger-kept index (compare the rows of both tables, and 50 queries' results, on a library built through the reconciler and OCR store; SC-005), and a library migrated from `v8` is searchable after `prepare`
- [X] T025 [US4] Implement `SearchIndex.state`, `prepare` and `rebuild` in `Packages/MemorriCore/Sources/MemorriCore/Search/SearchIndex.swift` per R8 and call `prepare` at launch from `App/AppEnvironment.swift` in the background; the previous task's tests pass
- [X] T026 [P] [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ShortcutValidatorTests.swift` (extend) that a search shortcut equal to the capture shortcut is refused with a reason and a system-reserved one is refused, and that clearing it is allowed
- [X] T027 [US4] Add the shortcut name `search` (default Control-Option-Command-F) and its handler in `App/Adapters/ShortcutAdapter.swift` (validated against the capture shortcut through `ShortcutValidator.otherActions`, rejection message and reset like capture), the `Search shortcut:` recorder and `Reset to default` in `App/Windows/ShortcutSection.swift`, the shortcut text on the menu item in `App/MenuContent.swift`, and the panel's `preparing` and `waiting to be analysed` states from `SearchState` and `SearchResults.waitingToBeAnalysed`; the previous task's tests pass
- [X] T028 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchFreshnessTests.swift` (extend) for captures: analysing a new capture makes its text searchable at once; reading a capture's text again replaces it (the old words are gone); `CleanupService.delete(olderThanDays: 30)` removes the text of old captures while the items made from them that were edited stay found; `delete(olderThanDays: nil)` leaves both tables empty; an item removed by the sweep is not found; the index survives an app restart (reopen the database)
- [X] T029 [US4] Make the tests of T028 pass (fix whatever they find in the triggers or `OCRStore`), and add the log lines of R12 (`search items=<n> captures=<n> ms=<n>`, `search index prepare done=<n> total=<n>`) in `SearchService` and `SearchIndex` with a test that a full search run writes no query or result text to a capturing logger and that the log lines contain only numbers (SC-007)
- [X] T030 [US4] Keep an open panel current: observe the search tables (GRDB `DatabaseRegionObservation`) in `App/Search/SearchViewModel.swift` so results refresh when the library changes while the panel is open

**Checkpoint**: tests pass; Debug build; the shortcut opens the panel from another app; a rebuilt index gives the same results.

---

## Phase 7: Polish and cross-cutting

- [ ] T031 [P] Scale tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SearchScaleTests.swift` (as `EvidenceScaleTests`): 5,000 items with aliases and 200 captures of 1,000 lines; a typical query (two words, one prefix) answers in under 200 ms (best of three), first results of an opening panel (empty filters) under 300 ms, a rebuild finishes and equals the incremental index, and storing a capture's text with the document costs no more than 5% more than without (SC-001, SC-005, SC-006)
- [ ] T032 Run `swift test --package-path Packages/MemorriCore` (all pass, no new warnings), `xcodegen generate`, a clean Debug build and a Release build (no debug ingest switches), and grep the diff for real names, company names, e-mail addresses and window titles; check that no log call in `Packages/MemorriCore/Sources/MemorriCore/Search` or `App/Search` carries a query, a title or a snippet
- [ ] T033 Run `specs/007-search/quickstart.md` in the app with an isolated home on the synthetic cases (`--ingest-case`), screenshots by window id, buttons through accessibility only; delete the scratch data and any preference keys the run set; time SC-004 by hand (one remembered word, from the shortcut to the opened item, under 10 s), check that the panel appears over a full-screen app (if macOS refuses activation, note it in `contracts/ui-contract.md` as a known limit), and record what could not be driven (the global shortcut needs another app in front and a key press)
- [ ] T034 Set ADR `docs/architecture/decisions/0023-search-index-in-the-library-database.md` to Accepted with the measured figures, update `CLAUDE.md` (stack paragraph: search; the active plan line), `DEVELOPER.md` (how the index is kept, the version to raise when a searchable column changes, how to rebuild), `docs/roadmap.md` (007 Done once everything passes), the contracts' "As built" notes where the code differs, and write `specs/007-search/pr-description.md` (what changed and why, spec and ADR linked, how it was verified with the numbers, what a reviewer should look at, known gaps); do not push or open a PR until the user asks

---

## Dependencies and order

- Phase 1 then Phase 2, then US1. US2 needs US1's service and panel; US3 needs US1 (items) and US2 (capture filters); US4's index tasks (T024 and T025) need only Phase 1, its shortcut tasks need US1's panel.
- Within a story: tests, then implementation, then UI.
- T004 and T005 can run in parallel; T010 can run in parallel with T007 to T009; T024 and T026 can run in parallel with each other.

## Implementation strategy

- **MVP**: Phases 1 to 3 (items in the panel from the menu). Stop and check the quickstart steps 2 and 3.
- Then US2 (captures), US3 (filters), US4 (shortcut, rebuild, retention), Polish. Commit at each checkpoint with a Conventional Commit and the `Co-Authored-By` line; never to `main`.
