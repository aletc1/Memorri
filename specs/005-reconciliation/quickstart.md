# Quickstart: validate reconciliation

Prerequisites: a Debug build (`xcodegen generate`, `xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build`), Ollama on localhost with the vision model of ADR 0019 and, for scenario 6, the embedding and reranker models of research R3 and R4. Run the app with an isolated home (`CFFIXED_USER_HOME=<scratch dir>`) so real data is not touched.

## 1. Core tests
`swift test --package-path Packages/MemorriCore` passes, including the sequence eval in `--models off` mode.
Expected: merge recall ≥ 0.95 on the cases without translations, every translated pair flagged as a possible duplicate, wrong merges ≤ 0.02, zero recreated dismissals, zero overwritten user titles (SC-001, SC-002, SC-005). The full SC-001 target including translations is checked with `--models on` in scenario 7.

## 2. Duplicates across captures (User Story 1)
Ingest two synthetic calendar cases that show the same meetings (`Memorri --ingest-case eval/golden/synthetic/<month case>` then the matching week case). Open `Items…`.
Expected: one item per meeting with `2 sightings`; different meetings at the same time are separate; the same title on other days is separate.

## 3. Reanalysis is idempotent (SC-003)
In Settings → Analysis press `Reanalyse` on one of those captures; wait.
Expected: the item count does not change and item ids (shown in the detail's History) stay the same.

## 4. Fields grow and keep their evidence (User Story 2)
Open an item seen in both views. Expected: the end time comes from the view that shows it and is marked `read`; a guessed end is `guessed` only if no view showed it; each field's sightings are listed with capture and `why`.

## 5. User rules (User Story 3)
Edit an item's title, dismiss another, then ingest a third case with both events. Expected: the edited title stays with a lock; the dismissed item gains a sighting but stays dismissed and hidden; `Restore` brings it back with all sightings; `Unlock` returns the title to the read value.

## 6. Manual merge, split, undo (User Story 4)
Merge two items; split a sighting off; undo the split, then the merge, from History. Expected: everything is back as before each step; after a split, re-ingesting the same case does not join the two again. With the matching models set to `None`, an unclear pair appears as `Possible duplicate`.

## 7. Eval (User Story 5)
`swift run --package-path Packages/MemorriCore memorri-eval reconcile --models on --out eval/out/reconcile-on.json`, then `--models off`, then `compare`.
Expected: the targets of scenario 1, judged share < 0.10, mean under 2 s per capture.
`memorri-eval run --reconcile` on the 27 synthetic cases: items ≤ distinct events, zero items created by the second pass (SC-007).

## 8. Cleanup
Delete all captures in Settings → Storage. Expected: items with no sightings disappear except edited, locked and dismissed ones.

## 9. Old captures
On a database from spec 004 with stored findings, launch the new build. Expected: the Items window is empty until a capture is analysed or reanalysed (clarification 4).

## Results (2026-10-01)

Run with the Debug build, `CFFIXED_USER_HOME` set to a scratch folder, Ollama with `qwen3-vl:8b-instruct` and the matching models, and pictures from `eval/golden/synthetic` only.

- **1 Core tests**: all pass, including the off-mode gate on the tracked sequences.
- **2 Duplicates across captures**: `--ingest-case eval/golden/synthetic/calendar-week-web-12h` twice and `calendar-month-web-24h` once. Log lines: `reconciled findings=3 created=3 merged=0 ... ms=51`, then `findings=3 created=0 merged=3 ... ms=7` for the repeat, then `findings=4 created=4 ... judged=1 ms=150` for the month view (first use of the matching models). The Items window listed 7 appointments; items seen twice show `2 sightings`; two different meetings at the same time stayed separate items. As expected.
- **Window actions**: selecting an item showed its fields with `read` / `guessed`, its sightings with `why: text-time (text 1.00, time 1.00)` and its History (`Merged automatically (automatic)`). `Dismiss` hid the item and `Undo last` brought it back, with the dismissal struck through in History. As expected. One difference found and fixed: after `Dismiss` the item stayed selected but its `Restore` button did not show, because the buttons only looked at visible rows.
- **3 Reanalysis (SC-003)**, **4 fields**, **5 user rules**, **6 merge, split, undo**, **8 cleanup**, **9 old captures**: not driven through the app window. Memorri never becomes the frontmost app, so keystrokes and text fields cannot be automated, and buttons could only be pressed by screen position (done for Dismiss and Undo last above). They are covered by tests instead: `ReconcilerTests` and `run --reconcile` (3), `ReconcilerFieldTests` (4), `ItemOperationsTests`, `ReconcilerTests` and the sequence cases (5), `ItemMergeSplitTests` and `UndoTests` (6), `CleanupServiceTests` (8), `StorageDatabaseTests` (9, migration v5 adds `reconciled_at` and `reconcile_error` as nullable columns, so earlier analyses are not reconciled).
- **7 Eval**: `reconcile --models on`: recall 1.000, wrong merges 0.000, judged share 0.083, 22 ms per capture; `--models off`: recall 1.000 without translations, translated pairs flagged 1.00, wrong merges 0.000, 3 ms; `compare` shows only the translated case changing (0/3 to 3/3 merged). `run --reconcile`: 48 findings, 46 items, 46 expected events, 0 new items after the second analysis.

