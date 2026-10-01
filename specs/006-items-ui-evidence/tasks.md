---

description: "Task list for spec 006: evidence cut-outs, review and the Inbox, inline editing"
---

# Tasks: See where every item comes from, fix it in place, and review the doubtful ones

**Input**: Design documents from `/specs/006-items-ui-evidence/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present), quickstart.md. Spec 005 is merged (items, sightings, observations, locks, operation log, Items window).

**Tests**: Included. The constitution (principle VI) requires `MemorriCore` logic to be test-first: write the test, see it fail, then implement. App views are proven by the quickstart.

**Organization**: Grouped by user story. US1 evidence, US2 review and the Inbox, US3 inline editing of every field, US4 browsing by kind and context with the review count. Paths follow plan.md; core is `Packages/MemorriCore/Sources/MemorriCore` and tests are `Packages/MemorriCore/Tests/MemorriCoreTests`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US4 as above
- Commands assume the repository root as the working directory.
- **Privacy**: tests and eval use synthetic titles and drawn pictures only; real captures and the user's real database are never opened or shown. Run the app for checks only with `CFFIXED_USER_HOME` set to a scratch folder, take screenshots only by window id, press buttons through accessibility (never by screen position), and delete scratch data afterwards.
- Tasks that edit `Tests/MemorriCoreTests/Fakes.swift` are not marked parallel.

## Phase 1: Setup

**Purpose**: Migration v6 and the folder for evidence, shared by every story.

- [x] T001 Write failing tests in `Packages/MemorriCore/Tests/MemorriCoreTests/StorageDatabaseTests.swift` for migration `"v6"` per `data-model.md`: table `evidence` with columns `id` (text primary key), `item_id` (not null, references `items(id)` ON DELETE CASCADE), `sighting_id` (null, references `sightings(id)` ON DELETE SET NULL), `image_id` (not null, no foreign key), `captured_at`, `display_name` (null), `title`, `cited_lines_json`, `region_json`, `file_path` (null), `reason` (null), `bytes` (not null, default 0), `created_at`; indexes `(item_id, captured_at)`, `(image_id)` and unique `(sighting_id)` where not null; `items` gains `needs_review` (integer, not null, default 0), `review_reasons_json` (text, not null, default `[]`), `approved_at` (datetime, null), `approved_values_json` (text, null) and an index on `(needs_review, status)`; deleting an item removes its evidence rows; deleting a sighting leaves the row with `sighting_id` null; a v5 database migrates with its rows intact
- [x] T002 Implement migration `"v6"` in `Sources/MemorriCore/Storage/Migrations.swift` per `data-model.md`; T001 passes
- [x] T003 [P] Add `AppPaths.evidence` (`<root>/evidence`, created by `prepare()` with mode 0700) in `Sources/MemorriCore/Storage/AppPaths.swift`, with a test in `Tests/MemorriCoreTests/AppPathsTests.swift` that `prepare()` creates it with mode 0700 and it sits inside the root that is excluded from backups

**Checkpoint**: `swift test` passes with a v6 database.

---

## Phase 2: Foundational

**Purpose**: The review columns on the `Item` type, read everywhere. No behaviour yet.

- [x] T004 Add `needsReview: Bool`, `reviewReasons: [ReviewReason]` and `approvedAt: Date?` to `Item` in `Sources/MemorriCore/Reconciliation/Item.swift` (defaults false, empty, nil), define `enum ReviewReason: String, Codable, CaseIterable` with raw values `low-confidence`, `guessed-start`, `guessed-end`, `guessed-due`, `possible-duplicate`, `changed-after-approval`, and read the four new columns in `ItemStore.item(from:)`; extend `ItemTypesTests.swift` and `ItemStoreTests.swift` so an item round-trips with reasons and approval

**Checkpoint**: existing tests still pass; items load with the new fields.

---

## Phase 3: User Story 1 - Show me the proof (Priority: P1) 🎯 MVP

**Goal**: Each sighting shows a saved cut-out around its cited lines, and the whole capture opens with the lines outlined. Cut-outs survive the capture, follow the sighting, and go with the item.

**Independent Test**: Analyse a drawn capture; open its item; see a cut-out per sighting; delete the capture by retention and see the cut-out stay; delete everything and see it go.

### Tests first

- [ ] T005 [P] [US1] Write failing tests in `Tests/MemorriCoreTests/EvidenceGeometryTests.swift`: `EvidenceGeometry.region(lines:pictureWidth:pictureHeight:)` returns the union of the boxes grown by a margin of 24 px or 15% of the union's height, whichever is larger, clamped to the picture (no padding past an edge); returns nil for no lines; `outputSize(for:)` keeps the size up to 1600 px wide and scales down proportionally beyond; every input box lies inside the region (table-driven, including a box at the picture edge and a very wide month-view row)
- [ ] T006 [P] [US1] Write failing tests in `Tests/MemorriCoreTests/EvidenceWriterTests.swift` using a drawn picture, `ReconcileFixture` and the real database: after `write(imageID:)` each sighting of the picture has an `evidence` row with the region of its cited lines, a HEIC file under `evidence/YYYY-MM/<id>.heic` of the expected size, `bytes` set and mode 0600; a sighting that cited no lines gets a row with `reason = "no-lines"` and no file; a picture that is missing gets rows with `reason = "picture-missing"`; writing again replaces the picture's rows and files (no leftovers); an encoder failure is swallowed, logged and leaves `reason = "failed"`; `write` returns how many cut-outs it saved and never throws
- [ ] T007 [P] [US1] Write failing tests in `Tests/MemorriCoreTests/EvidenceStoreTests.swift`: `evidence(itemID:)` lists newest first with the copied capture time, display, title and cited lines; `image(_:)` returns the saved cut-out and nil when the file is gone; `capture(_:)` returns the full picture with the stored OCR lines and nil once the picture is missing; `totalBytes()` sums `bytes`
- [ ] T008 [P] [US1] Write failing tests in `Tests/MemorriCoreTests/EvidenceLifecycleTests.swift`: merge, split and undo move `evidence.item_id` with their sightings; evidence whose sighting is gone (capture deleted by `CleanupService.delete(olderThanDays: 30)`) keeps its row and file and stays on its item; `CleanupService.delete(olderThanDays: nil)` removes every evidence row and file; an item removed by the sweep takes its evidence and files with it; reanalysis of a picture removes that picture's old evidence files; `CaptureFileStore.reconcile` removes files under `evidence/` that no row names and keeps the rest; the `Delete everything` preview (bytes) includes evidence
- [ ] T009 [P] [US1] Write failing tests in `Tests/MemorriCoreTests/EvidenceBackfillTests.swift`: `backfill(itemID:)` writes cut-outs for sightings that have none and whose picture is stored, skips those whose picture is gone, and is idempotent; `backfill(limit: 200)` handles at most the limit per call, newest sightings first

### Implementation

- [ ] T010 [US1] Implement `PixelRegion`, `EvidenceGeometry` in `Sources/MemorriCore/Evidence/EvidenceGeometry.swift` per research R2; T005 passes
- [ ] T011 [US1] Implement `EvidenceRecord`, `EvidenceStore` in `Sources/MemorriCore/Evidence/EvidenceStore.swift` per `contracts/core-interfaces.md`; T007 passes
- [ ] T012 [US1] Implement `EvidenceWriter` (`write`, `backfill(itemID:)`, `backfill(limit:)`) in `Sources/MemorriCore/Evidence/EvidenceWriter.swift`: decode the full picture once through `FullPictureProviding`, crop with `CGImage.cropping`, scale per `outputSize`, encode with `ImageEncoding.encodeAnalysisCopy(_:longEdge:)` using the cut-out's own long side (it never enlarges), write the file atomically (mode 0600) and insert the row in one transaction per picture; log `evidence image=<id> written=<n> skipped=<n> ms=<n>` (no text); T006 and T009 pass
- [ ] T013 [US1] Keep evidence consistent in `Sources/MemorriCore/Reconciliation/ItemMerge.swift` and `ReconcilerApply.swift` (update `evidence.item_id` wherever sightings move; remove a picture's evidence rows and files when its sightings are replaced), in `ItemStore.sweep` (remove evidence files of removed items), in `Storage/CleanupService.swift` (`olderThanDays == nil` removes all evidence and files; other deletes keep it; `preview` counts evidence bytes) and in `CaptureFileStore.reconcile` (orphan evidence files); T008 passes
- [ ] T014 [US1] Call the writer after reconcile in `Sources/MemorriCore/Analysis/ImageAnalysisJob.swift` (new optional `evidence: EvidenceWriter?` parameter; its outcome never changes the job's outcome) with a test in `ImageAnalysisJobTests.swift` using a fake writer; wire it in `App/AppEnvironment.swift` and run `backfill(limit: 200)` once at launch off the main actor
- [ ] T015 [US1] Add `evidenceBytes` to `StorageSummary` in `Sources/MemorriCore/Storage/StorageStats.swift` (summing `evidence.bytes`, counted from the files like the pictures) with a test in `StorageStatsTests.swift`, and show `Evidence: <size>` in `App/Windows/StorageSettingsView.swift` with the `Delete everything` confirmation text mentioning evidence
- [ ] T016 [US1] Create `App/Windows/EvidenceViews.swift` (a card with the cut-out, capture date and time, display, title as found, confidence and `why`; the texts `No cut-out: the finding cited no lines` and `The capture is no longer stored.`; a sheet that shows the full capture with the region and cited lines outlined) and use it in `App/Windows/ItemDetailView.swift`: the 5 newest sightings as cards with `Show all N sightings`, checkboxes for Split on the cards, images loaded off the main actor into an `NSCache` (100 images), `ItemsViewModel` calls `backfill(itemID:)` when an item opens; accessibility labels on every control
- [ ] T017 [US1] Build (`xcodegen generate`, `xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build`, no warnings) and run quickstart scenarios 2 and 3 in an isolated home, recording results under `Results` in `quickstart.md`

**Checkpoint**: US1 works alone: evidence is visible, kept and removed by the rules.

---

## Phase 4: User Story 2 - Review the doubtful ones in an Inbox (Priority: P1)

**Goal**: Items that need review (with reasons) are collected in the Inbox; approve and dismiss work with evidence in view; approval is undoable and returns on conflicting changes.

**Independent Test**: Analyse clear and doubtful synthetic captures; the Inbox lists only the doubtful; approve, dismiss and Undo last behave; a changed value brings an approved item back.

### Tests first

- [ ] T018 [P] [US2] Write failing tests in `Tests/MemorriCoreTests/ReviewRulesTests.swift` (table-driven) for `ReviewRules.reasons(...)`: `level` is 0.75; confidence 0.74 gives `low-confidence`, 0.75 does not; a chosen `inferred` start, end or due that is not locked gives `guessed-start`, `guessed-end` or `guessed-due`, a locked or read one does not; an open possible duplicate gives `possible-duplicate`; with an approval snapshot, a differing title, start, end, all-day or due gives `changed-after-approval`, equal values do not; reasons come in this fixed order; dismissed and merged items have none
- [ ] T019 [P] [US2] Write failing tests in `Tests/MemorriCoreTests/ReviewStateTests.swift` with `ReconcileFixture`: after reconciliation items have `needs_review` and reasons per R5 (a guessed end puts a 0.9-confidence item in the Inbox); `ItemStore.reviewCount(contextID:)` equals the number of rows with `needs_review = 1`; recompute after approve, unlock, merge, split, mark different, undo and a change of `possible_duplicates` keeps the columns right; the migration computes the columns for existing items
- [ ] T020 [P] [US2] Write failing tests in `Tests/MemorriCoreTests/ApproveTests.swift` (`ItemOperations`): `approve` stores `approved_at` and the snapshot of title, start, end, all-day and due, clears `needs_review` and writes an `approve` op; approving an item that does not need review is allowed; wrong status (dismissed, merged) throws; Undo restores the previous approval, `needs_review` and reasons exactly (snapshot equality as in `UndoTests`); a later sighting that changes an unlocked approved value returns the item to the Inbox with `changed-after-approval`, while locked fields do not; merging two approved items keeps the approval, one approved and one not clears it; a split-off item has no approval; older `reconcile_ops` rows without the approval fields still decode and undo
- [ ] T021 [P] [US2] Write failing tests in `Tests/MemorriCoreTests/ItemListModelTests.swift` (extend): `ItemFilter.scope` is `.all`, `.inbox` or `.approved`: `.inbox` lists only items with `needsReview`, newest sighting first, `.approved` only active items that do not need review (FR-016); `reviewText(_:)` gives `Low confidence`, `Guessed time`, `Guessed end`, `Guessed due date`, `Possible duplicate`, `Changed after you approved it`; `approvalText(_:)` gives `Needs review`, `Approved` or `Approved by you`; `canApprove(_ rows:)` is true when every selected item needs review; the empty Inbox text is `Nothing needs review.`; `undoTarget` includes `approve` operations

### Implementation

- [ ] T022 [US2] Implement `ReviewRules` in `Sources/MemorriCore/Reconciliation/ReviewRules.swift` per research R5 and `contracts/core-interfaces.md`; T018 passes
- [ ] T023 [US2] Compute and store `needs_review` and `review_reasons_json` in `ItemRecompute.swift` (using the chosen observation sources, locks, open possible duplicates and the approval snapshot) and make every path that changes `possible_duplicates` call the recompute; add `ItemStore.reviewCount(contextID:)` and `observeReviewCount()`; run the one-off computation for existing items after migration v6; T019 passes
- [ ] T024 [US2] Add `OperationKind.approve`, extend `ItemState` with optional `approvedAt` and `approvedValues` (absent in older entries) in `OperationLog.swift`, and implement `ItemOperations.approve` and the merge and split rules of `data-model.md` in `ItemOperations.swift` and `ItemMerge.swift`; undo restores the approval in `ItemUndo.swift`; T020 passes
- [ ] T025 [US2] Add `ItemFilter.scope` (`.all`, `.inbox`, `.approved`), `reviewText`, `approvalText`, `canApprove` and the empty-Inbox text to `Sources/MemorriCore/Reconciliation/ItemListModel.swift`; `operationText("approve")` is `Approved`; T021 passes
- [ ] T026 [US2] Add the scope control `Items · Inbox (N)`, reason labels on rows, the `Needs review` mark, `Approve` (toolbar, header and Return in the Inbox; ⌫ dismisses) and the empty-state text to `App/Windows/ItemsView.swift`, `ItemsViewModel.swift` and `ItemDetailView.swift` per `contracts/ui-contract.md`; selection is kept when the list updates
- [ ] T027 [US2] Build with no warnings and run quickstart scenarios 4 and 5 in an isolated home (press buttons through accessibility), recording results in `quickstart.md`

**Checkpoint**: US1 and US2: evidence and the Inbox work together.

---

## Phase 5: User Story 3 - Fix any field where I see it (Priority: P2)

**Goal**: Every field is editable inline, validated, locked, approving and undoable.

**Independent Test**: Edit start, place, people and notes of an item, analyse a capture with old values, see the edits stay; invalid edits are rejected with a message.

### Tests first

- [ ] T028 [P] [US3] Write failing tests in `Tests/MemorriCoreTests/ItemOperationsTests.swift` (extend): `edit` rejects an empty or blank title (`emptyTitle`) and a start after the item's resolved end or an end before its start (`startAfterEnd`, also when only one of them is edited), accepts equal start and end, trims and de-duplicates people, accepts `null` to clear place, notes, end, due and reminder (locked empty value), and approves the item in the same transaction (`approved_at` set, `needs_review` cleared); one Undo restores the field, its lock and the approval together; two edits in a row can be undone one at a time; an edit confirmed after a reconcile plan was made but before it is applied keeps the user's value (last confirmed edit wins)
- [ ] T029 [P] [US3] Write failing tests in `Tests/MemorriCoreTests/ItemListModelTests.swift` (extend): `parse(_:field:timezone:)` turns text into a `JSONValue` per field (date and time in the item's zone for start, end, due and reminder, names split on commas for people, trimmed text for title, place and notes, an empty string for an optional field means clear) and returns `EditError` messages for invalid dates and empty titles; `ItemListModel.valueText` and the editor's initial text round-trip through `parse`
- [ ] T030 [P] [US3] Write failing tests in `Tests/MemorriCoreTests/EditLockTests.swift` with `ReconcileFixture`: after editing start, place, people and notes, reconciling a later capture that shows the old values leaves the user's values and keeps them locked; the other values stay visible as observations of that field; `unlock` returns the value the sightings decide, and `fieldText` shows which that is

### Implementation

- [ ] T031 [US3] Implement the validation and the approving edit in `ItemOperations.swift` (`ItemOperationError.startAfterEnd`, `.emptyTitle`; people normalisation; clearing through `.null`); T028 and T030 pass
- [ ] T032 [US3] Implement `ItemListModel.parse` and `EditError` in `ItemListModel.swift`; T029 passes
- [ ] T033 [US3] Create `App/Windows/FieldEditor.swift` with the typed inline editors of `contracts/ui-contract.md` (text field for title and place, multi-line for notes, comma-separated people, date and time picker in the item's zone for start, end, due and reminder, all-day toggle, `Add` for empty fields; Return or `Save` confirms, Esc cancels, a red message under the field for a rejected value that keeps the old one) and use it for every row of `Fields` in `ItemDetailView.swift`; `ItemsViewModel.edit(field:text:)` runs off the main actor and shows `ItemsViewModel.text(for:)` messages for `startAfterEnd` and `emptyTitle`; accessibility labels on every control
- [ ] T034 [US3] Build with no warnings and run quickstart scenario 6 in an isolated home (typing cannot be automated in this app, so T028 to T030 cover the typing paths), recording results in `quickstart.md`; the typing paths are covered by T028 to T030

**Checkpoint**: US1 to US3.

---

## Phase 6: User Story 4 - Browse by kind and context, review count at a glance (Priority: P3)

**Goal**: Appointments, Tasks and Reminders are separate filters; the Inbox honours the context filter; the menu and the window show the same review count.

**Independent Test**: With items of all three kinds in two contexts every filter combination lists exactly the expected items, and the count matches the Inbox.

### Tests first

- [ ] T035 [P] [US4] Write failing tests in `Tests/MemorriCoreTests/ItemListModelTests.swift` (extend): `ItemKindFilter.reminders` lists only reminders, `.tasks` lists tasks and deadlines, `.appointments` only appointments, `.all` all (the existing `filtersByKindFamilyContextAndDismissed` test is updated because `.tasks` no longer includes reminders); the Inbox scope combines with kind and context filters; the count in the scope label equals `ItemStore.reviewCount(contextID:)` for the same context in every combination tested; rows show kind, title, date and time in the item's zone, context, approval mark and lock
- [ ] T036 [P] [US4] Write failing tests in `Tests/MemorriCoreTests/ItemStoreTests.swift` (extend): `observeReviewCount()` emits again after approve, dismiss, edit, merge and a new capture; `items(...)` takes a review filter and an index serves it (explain-query test or the scale test of T040)

### Implementation

- [ ] T037 [US4] Extend `ItemKindFilter` (`.reminders`, `.tasks` = task and deadline) and the row text in `ItemListModel.swift`; add the review filter to `ItemStore.items` and `observeItems`; T035 and T036 pass
- [ ] T038 [US4] Add `reviewCount` to `App/AppState.swift`, follow `observeReviewCount()` in `App/AppEnvironment.swift`, show `Inbox (N)` in `App/MenuContent.swift` (opening the Items window on the Inbox scope through `WindowCoordinator`), remove the placeholder `.inbox` window id and `PlaceholderView.inbox`, and update the kind control to `All · Appointments · Tasks · Reminders` in `App/Windows/ItemsView.swift`
- [ ] T039 [US4] Build with no warnings and run quickstart scenario 7 in an isolated home, recording results in `quickstart.md`

**Checkpoint**: all four stories.

---

## Phase 7: Polish and cross-cutting

**Purpose**: Scale, decisions, documentation and a PR a reviewer can trust.

- [ ] T040 [P] Write the scale test `Tests/MemorriCoreTests/EvidenceScaleTests.swift`: 5,000 items, 20,000 sightings with evidence rows; `evidence(itemID:)` plus loading five cut-outs for one item takes under 1 s and the Inbox query plus `reviewCount` under 0.5 s (best of three runs, as in `ReconcilerScaleTests`); and record the numbers in `research.md`
- [ ] T041 Run `swift test --package-path Packages/MemorriCore` (all pass, no new warnings), a clean Debug build and a Release build (no debug ingest switches), and grep the diff for real names, company names, user names and e-mail addresses; confirm `git ls-files eval` is unchanged
- [ ] T042 [P] Set ADR 0021 to Accepted with the measured figures (cut-out sizes, time to open an item and the Inbox), update `CLAUDE.md` (stack paragraph: evidence and the Inbox), `DEVELOPER.md` (where evidence lives, how to inspect it, the review level constant and how to change it with a migration of review state) and `docs/roadmap.md` (006 Done once everything passes)
- [ ] T043 Check the success criteria against measured evidence and write the table into `research.md` (a `Results` section): SC-001 from `EvidenceWriterTests` (every cited line inside, margin only), SC-002 from the detail view (two actions), SC-003 from `ReviewStateTests` and the quickstart, SC-004 timed by hand with ten drawn Inbox items (keyboard automation is not available here), or marked not measured, SC-005 from `EditLockTests`, SC-006 from `ApproveTests` and `ItemOperationsTests`, SC-007 from T040, SC-008 from `ItemOperationsTests`; mark any miss plainly and record it as a known gap
- [ ] T044 Update `specs/006-items-ui-evidence/contracts/*.md` where the code differs, then write `specs/006-items-ui-evidence/pr-description.md` (what changed and why, spec and ADRs linked, how it was verified with the numbers, what a reviewer should look at, known gaps); do not push or open a PR until the user asks

---

## Dependencies and order

- Phase 1 (T001 to T003) before everything; Phase 2 (T004) before the stories.
- US1 (T005 to T017) is independent of US2 and US3 and is the MVP. US2 (T018 to T027) needs only Phase 1 and 2; its UI tasks (T026) edit the same files as US1's (T016), so do US1 first. US3 (T028 to T034) needs `approve` from US2 (T024) because an edit approves. US4 (T035 to T039) needs US2 for the Inbox scope and count.
- Within a story: tests, then code, then app, then the quickstart check.
- Phase 7 after all stories.

## Parallel opportunities

- T003 with T001 and T002 (different files).
- US1: T005 to T009 can be written together.
- US2: T018 to T021 can be written together.
- US3: T028 to T030 can be written together.
- US4: T035 and T036.
- T040 and T042 in the polish phase.

## Implementation strategy

1. **MVP**: Phases 1 and 2 plus US1: the user sees the proof. Commit at the checkpoint.
2. Add US2 (the confidence gate spec 009 needs), then US3, then US4, committing at each checkpoint.
3. **Stop conditions**: if SC-001 (cut-outs contain every cited line) or SC-006 (undo exact) is missed, fix before moving on; do not weaken a target to pass; report any miss plainly in the PR text.
