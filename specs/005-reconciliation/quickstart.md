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
