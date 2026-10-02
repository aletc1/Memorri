# Quickstart: validate search

Prerequisites: Debug build; an isolated home (`CFFIXED_USER_HOME=<scratch>`, and remember preferences are not isolated: note the defaults the run sets) or the user's go-ahead for real data; synthetic cases only in commits.

1. **Core tests**: `swift test --package-path Packages/MemorriCore` passes (parser, items, aliases, captures, filters, freshness after every operation, rebuild equals incremental, scale).
2. **Items**: ingest the synthetic cases (`--ingest-case`); open the panel from the menu; type a title word with and without accents and capitals; Return opens the item (Story 1).
3. **Aliases and merge**: merge two items in the Items window; search either title: one item; undo: two (Story 1, Story 4).
4. **Captures**: search a word that is in a case's text but made no item; the capture is listed with its window name; Return opens the viewer with the line outlined (Story 2).
5. **Filters**: pick Tasks, then a context, then a date range; each narrows as in the acceptance scenarios; `Clear filters` restores (Story 3).
6. **Shortcut**: press ⌃⌥⌘F from another app; type; Escape closes; set a conflicting shortcut in Settings and read the message (Story 4).
7. **Retention**: delete captures older than 0 days in Settings → Storage; search a word only they held: no result; kept items still found (Story 4).
8. **Rebuild**: delete `search_meta` rows from a copy of the database and launch: `Search is being prepared`, then results equal to before (SC-005).
9. **Log**: `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri" && category == "search"'` shows counts only.
