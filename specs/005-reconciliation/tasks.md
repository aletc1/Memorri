---

description: "Task list for spec 005: turn findings into one list of items without duplicates"
---

# Tasks: Turn findings into one list of items without duplicates

**Input**: Design documents from `/specs/005-reconciliation/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. Anything that needs the real models or the real screen is proven by the spike in research R3 and R4 and by the quickstart scenarios; everything else uses fakes, the real database in temporary directories and the tracked synthetic sequences.

**Organization**: Grouped by user story. Story numbers follow the spec: US1 duplicates merge, US2 items grow with evidence, US3 the user wins, US4 manual merge, split and undo, US5 the Items window and the eval. Paths follow plan.md (`App/`, `Packages/MemorriCore/`, `eval/`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US5 as above
- Commands assume the repository root as the working directory.
- **Privacy**: tests and eval use synthetic titles only ("Daily standup", "Customer A", "Anna"); real captures and the user's real database are never opened. Run the app only with `CFFIXED_USER_HOME` set to a scratch folder.
- Tasks that edit `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift` are not marked parallel.

## Phase 1: Setup

**Purpose**: Make the stand-in server answer the two new call shapes so tests and the quickstart need no real models.

- [x] T001 Extend `scripts/fake-ollama.py` with `/api/embed` (returns one deterministic 8-dimension vector per input: counts of the lowercased text's character trigrams hashed into 8 buckets, then normalised, so equal texts give equal vectors and a truncated title is close) and `/api/generate` with `raw`, `logprobs` and `top_logprobs` (returns `yes` when the prompt's two titles share their first 8 normalised characters, else `no`, with plausible log probabilities); the existing modes (`invalid`, `slow`, `error`, `flaky`, `hang`) apply to both; document the new routes in the file header
- [x] T002 [P] Confirm `.gitignore` tracks `eval/golden/synthetic-sequences/` (the existing rule ignores every other folder under `eval/golden/`); add the exception if missing and extend `eval/golden/README.md` with one paragraph on sequence cases (format in `contracts/eval-cli.md`)

**Checkpoint**: `python3 scripts/fake-ollama.py` answers `/api/embed` and a raw `/api/generate` in every mode.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Migration v5, the item types, normalised titles, field resolution, the two new client calls, the meaning judge and the read side of the item store. Tests first, then code.

- [x] T003 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v5"` per `data-model.md`: the tables `items`, `sightings`, `observations`, `field_locks`, `item_aliases`, `keep_apart`, `possible_duplicates`, `reconcile_ops`, `reconcile_op_items`, `title_embeddings` exist with exactly the listed columns and NOT NULL flags; `image_analysis` gains `reconciled_at` (DATETIME, null) and `reconcile_error` (TEXT, null) and old rows read them as null; `items.status` accepts only `active`, `dismissed`, `merged`; `items.family` only `event`, `todo`; `items.kind` only `appointment`, `task`, `reminder`, `deadline`; `items.merged_into` references `items(id)`; `items.context_id` references `contexts(id)` ON DELETE SET NULL; `sightings.image_id` references `capture_images(id)` ON DELETE CASCADE and `sightings.item_id` references `items(id)` ON DELETE CASCADE, so deleting a capture removes its sightings and leaves items, observations and aliases; `observations.item_id`, `field_locks.item_id`, `item_aliases.item_id`, `keep_apart.item_a` and `item_b`, `possible_duplicates.item_a` and `item_b` are ON DELETE CASCADE; `observations.sighting_id` is nullable and ON DELETE CASCADE; primary keys `(item_id, field)` on `field_locks`, `(item_id, normalised)` on `item_aliases`, `(item_a, item_b)` on `keep_apart` and `possible_duplicates`, `(op_id, item_id)` on `reconcile_op_items`, `(normalised, model)` on `title_embeddings`; indexes `(context_id, family, day_key)` and `(status)` on `items`, `(item_id)` and `(image_id)` on `sightings`, `(item_id, field)` on `observations`, `(created_at)` on `reconcile_ops`, `(item_id)` on `reconcile_op_items`; `reconcile_ops.by_user` is NOT NULL; a v4 database gains the v5 tables without losing captures, findings or analysis
- [x] T004 Implement migration `"v5"` in `Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift` per `data-model.md`; the tests pass and databases with unknown migrations are still refused untouched
- [x] T005 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/TitleNormaliserTests.swift`: case folding, accent stripping ("Revisión" equals "revision"), collapsed spaces, dropped punctuation, a trailing `…`, `...` or `..` removed, empty and whitespace-only titles give an empty string, a non-Latin title is kept as is
- [x] T006 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemTypesTests.swift`: `KindFamily` maps appointment to `event` and task, reminder and deadline to `todo`; `ItemField` raw values match the `observations.field` column (`all_day` for all-day); `Item` round-trips through the store rows (added in T014)
- [x] T007 Implement `TitleNormaliser` (`Packages/MemorriCore/Sources/MemorriCore/Reconciliation/TitleNormaliser.swift`) and `Item`, `ItemStatus`, `KindFamily`, `ItemField`, `ObservationSource`, `Observation` (`Packages/MemorriCore/Sources/MemorriCore/Reconciliation/Item.swift`) per `contracts/core-interfaces.md`; T005 and T006 (except the store round-trip) pass
- [x] T008 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/FieldResolverTests.swift` for research R9: a locked user value wins over everything; a `read` observation beats an `inferred` one whatever the confidence; confidence differences under 0.1 count as equal and the more recent capture wins; a title that another is a truncation of loses to the longer one ("more complete"); a timed value beats an all-day one for `start`; people are the union of the sightings' people in first-seen order; `ResolvedFields` names the chosen observation per field; titles not chosen come back as aliases; no observations for a field gives nil
- [x] T009 Implement `FieldResolver` and `ResolvedFields` in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/FieldResolver.swift`; the tests pass
- [x] T010 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaClientTests.swift` (extend): `embed(model:inputs:timeout:)` posts `/api/embed` with `model` and `input` and returns one `[Float]` per input in order, a count mismatch or missing `embeddings` is `badResponse`; `generateNextTokenLogprobs(model:prompt:timeout:)` posts `/api/generate` with `raw: true`, `stream: false`, `options.num_predict` 1, `options.temperature` 0, `logprobs: true`, `top_logprobs: 5` and returns the top tokens with log probabilities; both reuse the existing error mapping (timeout, 5xx, 4xx, unreachable) and go through the loopback-only transport
- [x] T011 Implement `OllamaClient.embed` and `OllamaClient.generateNextTokenLogprobs` in `Packages/MemorriCore/Sources/MemorriCore/Inference/OllamaClient.swift`; the tests pass
- [x] T012 [P] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OllamaMeaningJudgeTests.swift` against `FakeOllamaTransport`: `embeddings(for:)` sends the titles prefixed `query: ` in one batch and returns the vectors; `sameEvent` builds the documented reranker template (system line, `<Instruct>` "Do these two calendar titles name the same event?", `<Query>` and `<Document>` each holding the title followed by its date and time and context, empty think block) and returns p(yes) from the top log probabilities summing `yes` and `Yes` against `no` and `No`; a missing logprobs field throws; `isAvailable` is false when the embedding or reranker model is `nil` or not in `/api/tags`; `NoMeaningJudge.isAvailable` is false and both calls throw `unavailable`; the instruction version string is `rerank-v1`
- [x] T013 Implement `MeaningJudging`, `JudgedSighting`, `OllamaMeaningJudge` and `NoMeaningJudge` in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/MeaningJudging.swift` and `OllamaMeaningJudge.swift`, with a cache of embeddings in `title_embeddings` (read before calling, written after); add `embeddingModel` and `rerankerModel` to `OllamaSettings` (defaults: the e5 and reranker names from research R3 and R4 when installed, else none) with tests in `OllamaSettingsTests.swift`; the tests pass
- [x] T014 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemStoreTests.swift` for the read side: `items(status:kinds:contextID:)` filters by status, family and context (a `nil` context means none) and returns sighting counts; `detail(itemID:)` returns an empty detail for an item with no history and throws `notFound` for an unknown id; `observeItems()` emits again after an insert; rows decode into `Item` with dates in UTC
- [x] T015 Implement `ItemStore` reads (`items`, `detail` shell, `observeItems`) in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemStore.swift` with helpers to insert and update item rows used by the reconciler; the tests pass (and the store round-trip of T006)
- [x] T016 Add `FakeMeaningJudge` (scripted embeddings, scripted p(yes) per pair, counters, an `unavailable` and a `throwing` mode) and a `ReconcileFixture` builder (a database with contexts, a picture, a finding with given title, times, kind, confidence and provenance) to `Packages/MemorriCore/Tests/MemorriCoreTests/Fakes.swift`

**Checkpoint**: migration v5 applies, the pure types and the client calls are tested, and the fixtures exist; nothing reconciles yet.

---

## Phase 3: User Story 1 - The same meeting seen twice is one item (Priority: P1) 🎯 MVP

**Goal**: Every analysed capture's findings become sightings of items; duplicates merge, different events stay apart, reanalysis creates nothing new.

**Independent Test**: Analyse (with the fake judge) several captures showing the same appointments in different views and with truncated titles; the list holds one item per real appointment, and a second analysis of any capture changes nothing.

- [x] T017 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/TitleSimilarityTests.swift` for research R6 (inputs normalised first): equal gives 1 and `equal`; "quarterly planning with the cust" against "quarterly planning with the customer" gives 0.95 and `truncation` (cut mid-word, shorter at least 8 characters); a prefix at a word boundary gives 0.95; a prefix shorter than 8 characters is `fuzzy`; small spelling differences ("standup" against "stand up") score high through edit distance; token overlap raises "review of the budget" against "budget review"; "design review" against "budget review" stays below 0.9; every alias of the candidate is compared and the best counts
- [x] T018 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/TimeAgreementTests.swift` for research R5: appointments on the same day in the context's time zone with overlapping intervals, or starts within 15 minutes, are candidates; different days are not, including a day boundary that differs between the Mac's zone and the context's zone; an all-day sighting is a candidate for any time that day and scores 0.5 against a timed one; scores 1 for the same start, 0.8 for overlap, 0.6 within 15 minutes; tasks and reminders are candidates when due dates are within 1 day or both undated, which scores 1; a task against an event is never a candidate (different family)
- [x] T019 [P] [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/MatchScorerTests.swift`, table-driven over the rules of research R7: `text ≥ 0.9` and `time ≥ 0.5` merges; same-time pairs with `text` 0.2 are `uncertain` (translations, rule 3); `text < 0.5` with different times and cosine unknown or below 0.88 is `new`; cosine 0.9 sends a low-text pair to `uncertain`; undated tasks merge only at `text ≥ 0.9` and never go to the judge below `text` 0.7; `decideAfterRerank` merges at p(yes) ≥ 0.5, is `new` below, and `new(rule: "judge-unavailable")` when the answer is nil; every decision names its rule; thresholds are the `ReconcileThresholds.default` values
- [x] T020 [US1] Implement `TitleSimilarity` (`Reconciliation/TitleSimilarity.swift`), `TimeSpan` and `TimeAgreement` (`Reconciliation/TimeAgreement.swift`), `MatchScores`, `MatchDecision`, `ReconcileThresholds` and `MatchScorer` (`Reconciliation/MatchScorer.swift`) per `contracts/core-interfaces.md`; T017 to T019 pass
- [x] T021 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReconcilerTests.swift` for the plan and apply halves, using the fixtures and `FakeMeaningJudge`: (a) "Daily standup" on a Tuesday at 09:00 then the same again in another capture creates one item with two sightings (scenario 1); (b) a truncated title at the same time joins the full-title item (scenario 2); (c) "Design review" and "Budget review" at the same time stay two items when the judge says no (scenario 3); (d) the same title on different days gives two items (scenario 4); (e) the same title and time in two contexts gives two items (scenario 5); (f) analysing the same picture again creates no items and the item ids do not change, including an item seen only on that picture (scenario 6, research R2, SC-003); (g) two findings of one picture that are duplicates become one item; (h) a finding sticks to the item of this picture's earlier sighting when title and time are equal (rule 0); (i) a translated pair at the same time goes to the judge and merges on yes; (j) with `NoMeaningJudge` or a throwing judge the uncertain pair becomes a new item plus a `possible_duplicates` row and `reconcile_error` stays null; (k) a finding in a different kind family is never merged; (k2) an appointment with no resolved start is matched like an undated task and does not repeat on the next capture; (l) a context of `nil` matches only `nil`; (m) every sighting stores `decision_json` with rule and scores (FR-019); (n) `apply` re-checks its targets: an item merged away or deleted since `plan` falls back to a new item; (o) findings stored before v5 on a picture with `reconciled_at` null are not touched until `reconcile` is called for it (clarification 4)
- [x] T022 [US1] Implement `Reconciler` (`plan`, `apply`, `reconcile`) in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/Reconciler.swift`: candidate retrieval by indexed context, family and day key; scoring with embeddings read from the cache and the judge only for the uncertain band; one write transaction that removes this picture's earlier sightings and their observations, attaches or creates items, writes one observation per field shown (source `read` or `inferred` from the finding's provenance, user never), recomputes touched items through `FieldResolver` and aliases, writes `possible_duplicates`, sets `reconciled_at` or `reconcile_error`, and removes items left without sightings only when not user-touched, locked or dismissed; judge failures never throw out of `reconcile`; T021 passes
- [x] T023 [US1] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ImageAnalysisJobTests.swift` (extend): after a successful save the job calls `reconcile(imageID:)` once; a reconcile error leaves the job `succeeded` and stores `reconcile_error`; a job that fails before saving does not reconcile; a retry that resumes after the save reconciles once; with automatic analysis off nothing reconciles
- [x] T024 [US1] Call the reconciler from `Packages/MemorriCore/Sources/MemorriCore/Analysis/ImageAnalysisJob.swift` after `AnalysisResultStore.save` and log `reconciled image=… findings=… created=… merged=… possible=… judged=… ms=…` and `reconcile failed image=… reason=…` in category `reconcile` with no titles; wire `Reconciler` and `OllamaMeaningJudge` (models from `OllamaSettings`, `NoMeaningJudge` when none) in `App/AppEnvironment.swift`; T023 passes and the app builds

**Checkpoint**: analysing captures builds a de-duplicated item table (visible in tests; the window comes in Phase 7). MVP boundary: stop here for a first review.

---

## Phase 4: User Story 2 - An item gets more complete as more captures arrive (Priority: P1)

**Goal**: Each field keeps every sighting with evidence and the current value is chosen by rule.

**Independent Test**: Reconcile two findings of one appointment, the second adding an end time and a place; the item shows both and every field traces back to its capture and lines.

- [x] T025 [US2] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReconcilerFieldTests.swift`: a guessed one-hour end is replaced by a later read end and the guess stays in the observations (scenario 1); a full title stays the item's title when a truncated one arrives and the truncated one is an alias (scenario 2); two sightings that disagree on a field with confidences within 0.1 give the more recent value and keep the other observation (scenario 3); a place and people seen only in the second sighting appear on the item; an all-day sighting joined by a timed one gives the timed value and `all_day` false; the item's kind is the most frequent among sightings, ties to the latest; the item's context is the first sighting's; `confidence` is the highest sighting confidence; `first_seen` and `last_seen` follow the capture times; `day_key` follows the resolved start (or due) in the item's time zone and is recomputed when it changes
- [x] T026 [US2] Make T025 pass in `Reconciler.swift` and `FieldResolver.swift` (recompute of kind, context, confidence, first and last seen, `day_key`, aliases from non-chosen titles including truncated forms); fix only what the tests show
- [x] T027 [US2] Write failing tests in `ItemStoreTests.swift` (extend) for `detail(itemID:)` (scenario 4): per field the observations with capture, source lines, confidence and `inferred`; the sightings with capture time, display, title as found, confidence and the stored decision; aliases; locks; possible duplicates; the item's operations (empty until Phase 5)
- [x] T028 [US2] Implement `ItemStore.detail` with `ItemDetail`, `FieldHistory` and `SightingRow` in `ItemStore.swift`, reading captures and cited lines through the existing stores; T027 passes

**Checkpoint**: every item field can be explained from its observations.

---

## Phase 5: User Story 3 - What the user changes or dismisses stays that way (Priority: P1)

**Goal**: Edited fields stay locked, dismissed events stay gone, cleanup keeps what the user touched.

**Independent Test**: Edit a title and dismiss another item, then reconcile captures that show both again; the edit stands and the dismissed item gains sightings but stays dismissed.

- [x] T029 [P] [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/OperationLogTests.swift`: `record` writes a `reconcile_ops` row with kind, `by_user`, items, moved sightings, before state and detail, plus one `reconcile_op_items` row per item; `ops(forItem:)` returns them newest first through the index; `by_user` is 0 for `auto_merge` and 1 for operations the user starts; an automatic merge is recorded once per applied plan, with every joined sighting inside, and not at all when nothing joined (data model note)
- [x] T030 [US3] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemOperationsTests.swift` (edit, unlock, dismiss, restore): `edit` writes a user observation (confidence 1), a `field_locks` row, sets `user_touched` and records an `edit` op; editing the title keeps the old one as an alias; `unlock` removes the lock, recomputes the field from the observations and records an op; `dismiss` sets status `dismissed` and records an op; `restore` sets `active` and records an op; operations on a `merged` item throw `merged`; each op stores the before state needed by research R10
- [x] T031 [US3] Write failing tests in `ReconcilerTests.swift` (extend) for the user rules: a later sighting with the old title leaves the user's title and adds an observation (scenario 1); a dismissed item with a matching sighting (same context, time, same or truncated title) gets the sighting and stays dismissed, no new item (scenario 2); a clearly different event at the same time as a dismissed one makes a new item (scenario 3); after `restore` later sightings merge into it again with its history (scenario 4); after `unlock` the field takes the rule's value (scenario 5); a locked `start` is not moved by a later sighting at another time (the sighting still joins when the title matches and the time agrees within the candidate window)
- [x] T032 [US3] Write failing tests in `ItemStoreTests.swift` and `Packages/MemorriCore/Tests/MemorriCoreTests/CleanupServiceTests.swift` (extend) for `sweep()` (research R11, FR-014): deleting a capture removes its sightings and observations; the item's fields are recomputed from the remaining sightings; an item left with none is deleted unless `user_touched`, any lock or `dismissed`; its log rows and `reconcile_op_items` stay; unused `title_embeddings` are removed; `CleanupService.delete` (which `RetentionService.apply` calls) runs the sweep and logs the number of items removed
- [x] T033 [US3] Implement `OperationLog` (`Reconciliation/OperationLog.swift`), `ItemOperations.edit/unlock/dismiss/restore` (`Reconciliation/ItemOperations.swift`), the lock handling in `Reconciler` (observations recorded, resolved value fixed by `FieldResolver`), tombstone attach (dismissed items stay candidates, status unchanged), `ItemStore.sweep` and the calls in `CleanupService` and `RetentionService`, and make the reconciler write its `auto_merge` ops through `OperationLog`; T029 to T032 pass

**Checkpoint**: the three P1 stories hold; the constitution's rules III and IV are tested.

---

## Phase 6: User Story 4 - Fix a wrong merge or a missed one, and undo (Priority: P2)

**Goal**: Manual merge and split, undo through the full history, and no silent re-joining after a split.

**Independent Test**: Merge two items by hand, check the combined history, undo, and see both items back unchanged; split and undo likewise.

- [x] T034 [US4] Write failing tests in `ItemOperationsTests.swift` (extend) for `merge(keep, other, lockChoices:)` (scenario 1 and 6): `other` becomes `merged` with `merged_into`, every sighting, observation, alias and lock moves to `keep`, fields recompute, `user_touched` is set, a `merge` op is recorded, a possible duplicate row for the pair is removed; two different locked values for one field throw `needsLockChoice([field])` and change nothing, and the same call with `lockChoices` keeps the chosen value and records the choice in the op detail (FR-013); merging an item with itself or a `merged` item throws
- [x] T035 [US4] Write failing tests in `ItemOperationsTests.swift` for `split(itemID, sightings:)` (scenario 2 and 5): the chosen sightings and their observations form a new item (status `active`, `user_touched`), both items recompute, aliases follow their sightings, locks stay with the original, a `keep_apart` row joins the two items, a `split` op is recorded; splitting off every sighting or none throws; and in `ReconcilerTests.swift` that re-analysing the same picture, or a new capture that scores equally against both items, does not attach the split-off finding to the original (`keep_apart` blocks, sticky rule 0 keeps it where it was)
- [x] T036 [US4] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/UndoTests.swift` for research R10: undoing `merge` restores both items, their fields, locks, aliases and statuses exactly (compare full snapshots before and after, SC-004); undoing `split` joins the sightings back and removes the `keep_apart` pair; undoing `dismiss`, `restore`, `edit` and `unlock` restores status and locks; undoing an `auto_merge` days later separates the two items and writes `keep_apart` (scenario 4); an undo of a merge after later captures joined the merged item gives `partly` or `undone` with later sightings left on the item they match now; an undo whose sightings were removed by cleanup gives `impossible`; the undo is itself recorded and undoable; an op that is already undone cannot be undone twice; operations that touched the same items later and are not undone yet restore only what they did not change
- [x] T037 [US4] Write failing tests in `ItemOperationsTests.swift` for `markDifferent(a, b)` (clears the possible duplicate and writes `keep_apart`, records an op) and `changeContext(imageID:to:)` (research R12a): the picture's sightings are planned again against the new context's items, moved or made into new items, items left empty are swept, a `context` op is recorded (`by_user` 1 when the user picked the context) and can be undone, and a user-chosen context stays `source = user` (spec 004 rule)
- [x] T038 [US4] Implement `ItemOperations.merge/split/markDifferent/changeContext/undo`, `UndoResult`, the `keep_apart` check in `Reconciler` candidate selection (candidate blocked when it has a `keep_apart` pair with the item that holds this picture's earlier sighting of the finding), and the call from the app's context picker (`App/Windows/AnalysisSettingsView.swift` through `AppEnvironment`) so changing a picture's context goes through `changeContext`; T034 to T037 pass

**Checkpoint**: every automatic or manual change can be reversed; the table can be repaired by hand.

---

## Phase 7: User Story 5 - See the result and measure it (Priority: P2)

**Goal**: An Items window to use all of the above, and `memorri-eval` scoring of matching on a tracked synthetic set.

**Independent Test**: Open the Items window after analysing a few captures and use merge, split, dismiss and undo; run `memorri-eval reconcile` and read merge recall and wrong merges.

### Eval

- [x] T039 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/SequenceCaseTests.swift`: `sequence.json` per `contracts/eval-cli.md` decodes (contexts, captures with findings and `event`, actions `dismiss`, `restore`, `editTitle`, `split`); an unknown action or a finding without `event` is rejected with a clear message; encoding is stable (same bytes every time)
- [x] T040 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ReconcileRunnerTests.swift`: a case with two sightings of one event that ended in one item has `mergeRecall` 1; one that ended in two items has 0.5 for that pair set and names the missed pair; two events in one item give `wrongMergeRate` above 0 and are listed; `judgedShare` counts pairs sent to the judge over compared pairs; `userRules` counts a recreated dismissed event and an overwritten user title; with models off the translated pairs are reported as `translatedFlagged` and left out of `mergeRecall`; the report JSON round-trips and `compare` prints differences
- [x] T041 [US5] Implement `SequenceCase.swift`, `SyntheticSequences.swift` (generator for the set listed in `contracts/eval-cli.md`: truncations mid-word and at a word, view changes with and without end time, English and Spanish titles, accents and case, two different meetings at one time with a shared word, a recurring meeting on five days, two contexts, all-day against timed, undated tasks with near titles, dismissal then more sightings, a title edit then more sightings, the same picture twice) and `ReconcileRunner.swift` (in-memory database, fake clock, actions applied through `ItemOperations`, metrics per case and overall); T039 and T040 pass
- [x] T042 [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/EvalCommandTests.swift` (extend): `generate-sequences [--out]`, `reconcile [--cases] [--models off|on] [--embedding-model] [--reranker-model] [--address] [--out] [--only]`, `run --reconcile`, `--min-merge-recall` and `--max-wrong-merge` (exit 3 when missed), `compare` on reconcile reports, a non-local address is refused as in spec 004; `--models off` never opens a connection
- [x] T043 [US5] Implement the commands in `Packages/MemorriCore/Sources/MemorriCore/Evaluation/EvalCommand.swift` and `Sources/memorri-eval/main.swift` (including `run --reconcile`: analyse and reconcile every case, again a second time, report items against distinct expected events and items created by the second pass); run `memorri-eval generate-sequences` and commit the generated `eval/golden/synthetic-sequences/`; check that running it twice produces no diff; T042 passes and a sequence test in `swift test` runs `--models off` and asserts the off-mode gate (merge recall ≥ 0.95 without translations, every translated pair flagged, wrong merges ≤ 0.02, zero recreated dismissals, zero overwritten user titles)
- [x] T044 [US5] Tune and record thresholds (Constitution VI), and check scale (with 5,000 items in 20 contexts, planning a 250-finding capture takes under 2 s without the judge; a test in `ReconcilerTests.swift`): run `swift run --package-path Packages/MemorriCore memorri-eval reconcile --models on --out eval/out/reconcile-on.json` and `--models off`, then `compare`; adjust `ReconcileThresholds.default` only for a reason shown by the missed and wrong merges, rerun the 27 captures with `run --reconcile` using `qwen3-vl:8b-instruct`, and write the final thresholds and numbers (merge recall with models on, wrong merges, judged share, ms per capture, items against events, second-pass creations) into `research.md` R7 and ADR 0020; stop and report if SC-001, SC-002, SC-003 or SC-006 are missed

### App

- [x] T045 [P] [US5] Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/ItemListModelTests.swift` for the window's logic, kept in the core so it is testable: filtering by kind, context and `Show dismissed`; sort by start or due then title (undated last); row text for date and time in the item's zone, `No date`, `N sightings`, the possible-duplicate badge and the lock flag; `Merge` is enabled for exactly two selected non-merged items; `Undo last` targets the newest `by_user` op not undone and is disabled when none; `Split` needs at least one sighting left behind; a merge needing a lock choice yields the sheet's two values
- [x] T046 [US5] Implement `ItemListModel` (`Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemListModel.swift`); T045 passes
- [x] T047 [US5] Add the `.items` window id (title `Memorri Items`, resizable, default 900 × 600, size remembered like Settings) to `App/Windows/WindowCoordinator.swift` and an `Items…` button above `Inbox` in `App/MenuContent.swift`
- [x] T048 [US5] Create `App/Windows/ItemsView.swift` and `App/Windows/ItemDetailView.swift` per `contracts/ui-contract.md`: filter bar, multi-select list with badges, toolbar (`Merge`, `Dismiss` / `Restore`, `Undo last`), empty state text, header with editable title, `Fields` with source and lock, `Sightings` with checkboxes and `Split into new item`, `Other titles`, `Possible duplicates` with `Merge` and `Different`, `History` with per-op `Undo`, the lock-choice sheet, inline error messages; actions run off the main actor and the list updates from `observeItems()`; accessibility labels on every control
- [x] T049 [US5] Add the `Matching models` group (`Meaning (embeddings)` and `Same-event judge (reranker)` pickers listing installed models plus `None`, with the note from `contracts/ui-contract.md`) to `App/Windows/OllamaSettingsView.swift`, saved in `OllamaSettings`; rebuilding the judge on change in `AppEnvironment`
- [x] T050 [US5] Build with `xcodegen generate` and `xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build`; the build has no warnings; the Release build still has no debug ingest switches

**Checkpoint**: the app lists and repairs items; the eval measures matching.

---

## Phase 8: Polish and cross-cutting

**Purpose**: Prove the quickstart end to end, record the decisions, leave the repository in a state a reviewer can trust.

- [x] T051 Run quickstart scenarios 2 to 6, 8 and 9 in the app with an isolated home and the fake or real local server (drawn pictures through `--ingest-case`; never real captures); record the `ms=` values of the `reconciled` log lines next to the eval figure (FR-018) and in `quickstart.md` under a `Results` heading what happened and any difference from the expected outcome; if a scenario cannot be run, say which and why
- [x] T052 Check the success criteria against measured evidence and write the table into `research.md` (a `Results` section): SC-001 and SC-002 from T044, SC-003 from `run --reconcile`, SC-004 from `UndoTests` (snapshot equality), SC-005 from the sequence eval, SC-006 from T044, SC-007 from `run --reconcile` and the two-action path from a capture to its item in the window, SC-008 from `ItemStoreTests` detail and the `why` column; mark any miss plainly and record it as a known gap
- [x] T053 [P] Update `CLAUDE.md` (commands: `generate-sequences`, `reconcile`, `run --reconcile`; the Items window in the stack paragraph) and `DEVELOPER.md` (a short section on changing matching thresholds: run the sequence eval both modes and compare before and after), and `docs/roadmap.md` (005 Done once everything else passes)
- [x] T054 [P] Set ADR 0020 to Accepted with the measured thresholds, and check that `spec.md`, `plan.md`, ADR 0020 and the tasks agree on names (`Items window`, `sighting`, `possible duplicate`, `keep_apart`)
- [x] T055 Run `swift test --package-path Packages/MemorriCore` (all tests pass, no new warnings) and a clean Debug build; grep the diff and `eval/golden/synthetic-sequences/` for real names, companies, usernames or e-mail addresses; confirm `git ls-files eval` lists only the READMEs, `synthetic/` and `synthetic-sequences/`
- [x] T056 Write `specs/005-reconciliation/pr-description.md` (what changed and why, the spec and ADRs linked, how it was verified with the numbers, what a reviewer should look at: the thresholds and any scoring or set changes that moved numbers, known gaps)

---

## Dependencies and order

- Phase 1 (T001, T002) has no prerequisites; T001 is needed by the quickstart only.
- Phase 2 blocks everything: T003 then T004; T005 and T006 in parallel, then T007; T008 then T009 (needs T007); T010 then T011; T012 then T013 (needs T011); T014 then T015 (needs T004 and T007); T016 last in the phase (needs T013 and T015).
- US1 (Phase 3) needs Phase 2: T017 to T019 in parallel, then T020; T021 then T022 (needs T020); T023 then T024.
- US2 (Phase 4) needs US1; US3 (Phase 5) needs US1 and can run in parallel with US2 (different tests, same `Reconciler.swift` edits, so merge in order T026 then T033).
- US4 (Phase 6) needs US3 (the operation log and the edit and dismiss operations).
- US5 (Phase 7): the eval half (T039 to T044) needs US3 for its dismissal and edit actions and US4 for `split`; the app half (T045 to T050) needs US4. The two halves are independent of each other.
- Phase 8 needs everything.

## Parallel examples

- Phase 2: T005, T006, T008, T010 and T012 are separate test files and can be written at once.
- US1: T017, T018 and T019 can be written together; T039, T040 and T045 in US5 likewise.
- US5: after T041, the eval tasks (T042 to T044) and the app tasks (T046 to T049) can proceed in parallel by two people or sessions.

## Implementation strategy

1. **MVP**: Phases 1 to 3. After T024 the app builds a de-duplicated item table in the background; the tests prove the behaviour, and nothing in the UI changes yet.
2. **P1 complete**: Phases 4 and 5 add field evidence and the user's rules; this is the point where the constitution's III and IV hold, and the point to review before the repair tools.
3. **P2**: Phase 6 adds repair and undo; Phase 7 adds the window and the measurements, and sets the thresholds on evidence.
4. **Stop conditions**: if T044 shows SC-001, SC-002 or SC-003 missed, fix matching before the window work is merged; do not lower a target to pass.
5. Commit after each phase checkpoint on branch `005-reconciliation` (English Conventional Commits, `feat(reconciliation): …`); do not push or open the PR until asked.
