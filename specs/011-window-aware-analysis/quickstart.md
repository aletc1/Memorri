# Quickstart: validate window-aware analysis

Prerequisites: Debug build, Ollama with `qwen3-vl:8b-instruct`, an isolated home (`CFFIXED_USER_HOME=<scratch>`) or the user's go-ahead for their own data; synthetic cases only in commits.

1. **Core tests**: `swift test --package-path Packages/MemorriCore` passes (visibility, clock, conflicts, priority, re-read enqueue, reconciliation across windows).
2. **Eval, before and after**: `memorri-eval run --out eval/out/before.json` on `main` of this branch's base, then after; `memorri-eval compare`. Expected: the 28 existing cases within 0.02 per case; the five `windows-*` cases at full date accuracy; model calls per case ≤ 1 + relevant non-month windows; mean time per case at most +25% (SC-004, SC-005).
3. **Calendar and mail** (`--ingest-case eval/golden/synthetic/windows-calendar-and-mail`): items from both windows, each sighting naming its window in the detail (Story 1, Story 4).
4. **Other month with a menu clock** (`windows-month-other-month-menu-clock`): entries in the window's month; the analysis records `reference_source = screen-clock` (Story 2, Story 3).
5. **No stack**: ingest a case with one window; findings equal the old path's (FR-010).
6. **Library re-read**: in an isolated home with a few analysed captures (one with its picture deleted), launch the new build: `reread` jobs are queued with priority 1 behind a new capture; the deleted one is skipped; locked and approved values are unchanged afterwards (SC-009).
7. **Real library (counts only, with the user's go-ahead)**: after the re-read, the month views that show a month other than the capture's are dated in that month or flagged (SC-008).
