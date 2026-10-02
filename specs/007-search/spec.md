# Feature Specification: Find anything Memorri has seen

**Feature Branch**: `007-search`

**Created**: 2026-10-02

**Status**: Draft

**Related ADRs**: 0020 (items, sightings and the operation log), 0021 (evidence and review state), 0022 (window-aware analysis)

**Input**: User description: "Indexed full-text search (FTS5) over items, aliases and OCR text, with filters by kind, context and date range, and a quick-search panel reachable from the menu. (Specs 005, 006 and 011 already ship items with sightings and aliases, the Items window with its Inbox, and stored OCR lines per capture with window names; this spec adds searching them: type a few words and get matching items first, then captures whose text matched, open an item in the Items window, narrow by kind, context and date range, and reach it from the menu bar and a configurable shortcut. Everything stays local; search results must stay in step as captures are analysed, items are edited, merged, dismissed or removed, and when retention deletes captures.)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Type a few words, get the item (Priority: P1)
Someone remembers part of a meeting or a task ("pruebas", "grant", "budget fig") but not when it was or where it appeared. They open a quick-search panel from the menu bar or with a shortcut, type, and see matching items at once, best matches first, each with its kind, date, context and the words that matched. Return opens the chosen item in the Items window.

**Why this priority**: this is the point of keeping everything in one index; without it the user scrolls lists. It also works on the data that already exists (items, aliases), so it is useful before anything else here.

**Independent Test**: With a library of items, type part of a title, part of an alias (a title the item was also seen under) and a word from the notes or place; each gives the item, accents and capital letters do not matter, a word being typed matches by its beginning, and Return opens the item in the Items window.

**Acceptance Scenarios**:
1. **Given** an item titled "Café - Pruebas", **When** the user types `cafe pru`, **Then** the item is listed with the matching words marked.
2. **Given** an item that was seen as "Sprint planning" and later as "Sprint planning (moved)", **When** the user searches for "moved", **Then** the item is found through its alias and the result says it matched an alias.
3. **Given** results are shown, **When** the user moves with the arrow keys and presses Return, **Then** the Items window opens on that item (on the scope that shows it) and the panel closes.
4. **Given** nothing matches, **When** the user has typed at least one word, **Then** the panel says so and offers to search again without filters if any are on.

---

### User Story 2 - Find the capture a line of text came from (Priority: P2)
The text of every analysed capture is searchable too. After the items, the results list captures whose text matched (an email line that never became an item, a name on a calendar), each with when it was captured, the display, the window it was in, and the line that matched with context. The user can open the capture and see the matching lines marked.

**Why this priority**: it answers "where did I see that?" for things that are not items, and it is where most of the data is. It builds on the stored text and the whole-capture view that exist.

**Independent Test**: Capture-analyse a picture whose text includes a word that produced no item; search it; the capture is listed after the items with its time, window name and the matching line; opening it shows the picture with that line outlined, or says the picture is no longer stored while still showing the text.

**Acceptance Scenarios**:
1. **Given** a capture with the line "Invoice 2291 due Friday" and no item from it, **When** the user searches `2291`, **Then** the capture is listed with that line and its time, display and window.
2. **Given** a capture whose picture was deleted by retention but whose text is kept, **When** it matches, **Then** it is listed and opening it shows the text lines and says the picture is gone.
3. **Given** a word matches in many captures, **When** results are shown, **Then** the newest captures come first, at most a page of them, with "Show more" for the rest.
4. **Given** the same text appears in the same place in several captures of the same screen, **When** it matches, **Then** each capture is its own result (they are different moments), and the items they produced are listed once above.

---

### User Story 3 - Narrow by kind, context and date (Priority: P2)
The user narrows results by kind (appointments, tasks, reminders, or captures only), by context (a customer or "no context"), and by date range, from controls in the panel and in a search field of the Items window. Filters combine and each can be cleared; the active ones are always visible.

**Why this priority**: with months of captures a word returns too much; filters make results useful. Small once US1 exists.

**Independent Test**: With items of three kinds in two contexts across two months, search one word and apply each filter alone and together; results shrink to exactly the matching ones, and clearing a filter brings them back.

**Acceptance Scenarios**:
1. **Given** results for "review", **When** the user picks Tasks, **Then** only tasks (and deadlines) remain among the items, and captures are hidden unless "Captures" is also chosen.
2. **Given** a context is chosen, **When** results are shown, **Then** items of that context and captures assigned to it remain; "No context" shows those without one.
3. **Given** a date range, **When** results are shown, **Then** an item is kept if its start (or due) date is in the range, and a capture if it was taken in the range; an item with no date is kept only when no range is set.
4. **Given** filters that leave nothing, **When** the panel shows the empty result, **Then** it says which filters are on and has one button to clear them.

---

### User Story 4 - Reach it from anywhere, and keep it in step (Priority: P3)
The panel opens from a menu item and from a global shortcut the user can change in Settings (it can be cleared). It appears over whatever app is in front, takes keyboard focus ready to type, and closes with Escape. Results always reflect the library as it is now: a new capture's text is searchable once analysed, an edited, merged, dismissed or restored item shows its current state, an item removed by retention or Delete everything disappears, and text of captures that retention deleted disappears with them.

**Why this priority**: access and freshness make the feature trustworthy, but they only matter once there is something to find.

**Independent Test**: Open the panel with the shortcut from another app; type; Escape closes it. Then analyse a new capture, edit a title, merge two items, dismiss one, and delete old captures; after each, a search shows the new state without restarting.

**Acceptance Scenarios**:
1. **Given** another app is in front, **When** the user presses the shortcut, **Then** the panel opens with the cursor in the search field, and Escape or clicking elsewhere closes it.
2. **Given** a title was just edited, **When** the user searches for the new title, **Then** the item is found, and the old title still finds it through the alias if it was one.
3. **Given** two items were merged, **When** the user searches for either title, **Then** one item is listed; after undoing the merge, two are.
4. **Given** an item was dismissed, **When** searching, **Then** it is hidden unless "Include dismissed" is on, in which case it is marked dismissed.
5. **Given** retention deleted a capture, **When** the user searches for text only that capture held, **Then** nothing is found; items made from it that the user kept are still found.
6. **Given** the shortcut conflicts with another one or is cleared, **When** Settings is open, **Then** the user is told and the menu item still works.

---

### Edge Cases

- A search of one letter or only punctuation does not search; the panel asks for more.
- Very common words ("de", "the") are searchable but never hide rarer matches: results are ordered by how well and how rarely the words match.
- Text in several languages and with accents: `cafe`, `Café` and `CAFÉ` are the same; `ñ`/`n` are treated as different only when typed exactly.
- Quotes search a phrase (`"daily standup"`); a minus sign excludes a word; other punctuation is ignored, and a bad query never shows an error or crashes.
- Words typed in any order all must match (not any); the user can type a prefix of the last word while typing.
- A capture with thousands of lines is still one result, with its best matching lines (up to three) shown.
- The library is empty or still being analysed: the panel says there is nothing to search yet, or that some captures are still waiting to be analysed (with how many).
- The index is damaged or missing (older library, interrupted launch): the app rebuilds it in the background, search says "Search is being prepared" meanwhile, and nothing is lost, because the index is derived from stored data.
- Two panels at once: pressing the shortcut while the panel is open focuses it.
- Result text may contain private words; nothing from a search (queries, results, snippets) is logged, and the index is part of the library and removed by Delete everything.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST search the title, notes, place, people and aliases of items, and the recognised text of every analysed capture, with all words of the query required.
- **FR-002**: Matching MUST ignore case and accents, match the beginning of the last word typed, support quoted phrases and excluded words, and treat any other input as plain words without ever failing.
- **FR-003**: Results MUST list items first, then captures; within each group, better matches first (all words, rarer words, title over other fields), ties by newest.
- **FR-004**: Each item result MUST show its kind, its date, its context, its status when not active (dismissed, needs review), where it matched (title, alias, notes, place, people) and the matching words marked.
- **FR-005**: Each capture result MUST show when it was taken, the display, the window (application and title, when recorded), and up to three matching lines with the words marked.
- **FR-006**: Opening an item result MUST open the Items window on that item, on the scope that lists it; opening a capture result MUST show the whole capture with the matching lines outlined, or the text lines and a note when the picture is no longer stored.
- **FR-007**: The user MUST be able to filter by kind (appointments, tasks, reminders, captures), by context (one, or none), and by a date range; filters combine, are always visible, and can be cleared one by one or all at once.
- **FR-008**: Dismissed items MUST be hidden by default and shown, marked, with an "Include dismissed" choice; merged items MUST never appear separately from the item they were merged into.
- **FR-009**: A quick-search panel MUST open from a menu-bar menu item and from a global shortcut the user can change or clear in Settings, show over any app, put the cursor in the search field, move through results with the keyboard, and close with Escape.
- **FR-010**: The Items window MUST have a search field with the same query rules and filters that narrows its list to the matching items.
- **FR-011**: The index MUST follow the library: analysing a capture, reconciling, editing, locking, approving, dismissing, restoring, merging, splitting and undoing each update what search finds without a restart, and a deleted capture or removed item leaves no trace in results.
- **FR-012**: The index MUST be derived only from stored data, so it can be rebuilt completely at any time; a missing, damaged or outdated index MUST be rebuilt in the background while search says it is being prepared.
- **FR-013**: Searching MUST not delay capture or analysis, and typing MUST show results as the user types (results for the previous text are replaced, never mixed).
- **FR-014**: Search MUST stay on this Mac: no query, result or text is sent to any service, and no query text, result or snippet is written to logs.
- **FR-015**: Delete everything (Settings, Storage) MUST remove the search index with the rest of the library, and retention MUST remove the text of the captures it deletes.
- **FR-016**: The panel MUST be usable with the keyboard alone and with VoiceOver: every result and filter has a spoken label and the empty, preparing and error states are announced.

### Key Entities

- **Search query**: what the user typed (words, quoted phrases, excluded words) and the filters in force (kinds, context, date range, include dismissed).
- **Item result**: an item with the reason it matched (field, alias) and the marked words.
- **Capture result**: a capture with its matching lines, time, display and window.
- **Search index**: the derived, rebuildable record of searchable text of items, aliases and captures; belongs to the library.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a library of 5,000 items and 200,000 recognised lines, results for a typical query appear in under 200 ms after the last key, and the first results of an opening panel in under 300 ms.
- **SC-002**: 100% of the items in a test library are found by any word of their title, notes, place, people or aliases, typed in any case and with or without accents.
- **SC-003**: After each of: analysing a capture, editing, merging, splitting, undoing, dismissing, restoring and retention, a search shows the new state with no stale or missing result (checked on every operation by tests).
- **SC-004**: A user finds an item they remember by one word in under 10 seconds from the shortcut, with at most the keys typed and Return.
- **SC-005**: Rebuilding the whole index from stored data gives results identical to the incrementally kept one on the test library (100% of queries equal).
- **SC-006**: Search adds no more than 5% to the time of analysing a capture and no visible delay to capture.
- **SC-007**: No query text or result text appears in the log in a full run of the tests and the app (0 lines).

## Assumptions

- The index is part of the local database and is kept up to date in the same step as the data it describes; a launch checks it and rebuilds it if it is missing or older than the data format.
- Items are searched by their current values and every title they were seen under; each sighting's cited text is already part of the capture's text and is not indexed twice.
- "Date" of an item is its start for appointments and its due date for tasks and reminders (the date the Items window already sorts by); items without one match only when no date range is set. Captures use the time they were taken.
- The default shortcut is Control-Option-Command-F, chosen to avoid the capture shortcut and system ones; it is configurable like the capture shortcut.
- Languages: Spanish and English first (the user's libraries), but matching is by letters and accents, with no language-specific word stemming.
- Results are limited to a page (20 items and 20 captures) with "Show more"; ranking is simple and explainable, no model is used and no embeddings are needed.
- The panel is a floating window like the capture feedback, not a full app window; the Items window is opened for details.
- Search across the OCR text of captures from before spec 011 (read as one picture) works the same; the window name is shown when it was recorded.
- Out of scope: saved searches, search history, searching inside evidence images, fuzzy (typo-tolerant) matching, searching text of Settings or logs, and exporting results. Reprocessing (spec 008) and EventKit sync (spec 009) are not affected.
