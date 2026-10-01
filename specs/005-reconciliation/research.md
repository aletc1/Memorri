# Research: reconciliation

Decisions for [plan.md](plan.md). Each one has a decision, the reason and what else was considered.

## R1. Where reconciliation runs

- **Decision**: a `reconcile` step at the end of the existing `analyse` job (spec 004), after `AnalysisResultStore.save`. It is split in two: `Reconciler.plan` (async: read candidates, call the meaning judge, decide) and `Reconciler.apply` (one write transaction: delete the picture's earlier sightings, attach or create, recompute the touched items, write the log). A failure in either half is logged, the picture is marked `reconcile_failed` on `image_analysis`, and the job still succeeds; the next analysis or a "Reconcile again" button retries.
- **Rationale**: the queue is serial (spec 003), so two reconciliations never run together and the order of captures is kept. Network calls cannot sit inside a database transaction, hence plan then apply. `apply` re-checks that each target item still exists and is not merged away (a manual operation may have happened in between) and falls back to a new item otherwise.
- **Alternatives**: a separate job kind (more queue states for no gain); a trigger in SQL (cannot call the models); reconciling inside `save` (would put network calls in the transaction).

## R2. Reanalysis keeps the same items

- **Decision**: `plan` scores the new findings against items as they are, including sightings from this picture's previous analysis. `apply` then removes those earlier sightings and attaches the new ones. Reanalysis therefore reflects the latest read of each picture; an earlier, better read is not kept (the comparison of analyses before applying one is spec 008). An item left with no sightings is removed only after the new ones are attached, and only when it is not user-touched or dismissed (FR-014).
- **Rationale**: if old sightings were removed first, an item seen only on this picture would have no candidate, would be recreated with a new id, and would lose its log and identity. SC-003 tests that a second analysis creates zero items.
- **Alternatives**: keeping old sightings beside new ones (double counting, stale values); matching findings by id (ids change on each run).

## R3. Embedding model (spike, 2026-10-01)

- **Decision**: `jeffh/intfloat-multilingual-e5-large-instruct:f32` via `/api/embed`, input prefixed `query: `, vectors cached per normalised title in `title_embeddings`. Cosine is one feature of the score, never a decision on its own.
- **Spike** (Ollama 0.34.4): 1024 dimensions; batch of 10 cold 1.7 s, one warm 18 ms. Cosines: truncated title 0.959; "Revisión de presupuesto" / "Budget review" 0.915; "Design review" / "Budget review" **0.866**; "Daily standup" / "Reunión diaria" 0.856; unrelated 0.782. The range is compressed and a different meeting with a shared word scores like a translation, so cosine cannot separate them alone.
- **Alternatives**: Apple `NLEmbedding` (sentence embeddings exist for a few languages, weaker across languages); no embeddings (loses cross-language matches).

## R4. Judging the uncertain band

- **Decision**: the local reranker `fanyx/Qwen3-Reranker-0.6B-Q8_0:latest` through `/api/generate` with `raw: true`, `num_predict: 1`, `logprobs: true`, `top_logprobs: 5`, and its documented yes/no template with the instruction "Do these two titles name the same event?" plus both times as text. The probability of `yes` (summing `yes`/`Yes` against `no`/`No` in the top log probabilities) is asked in both orders of the two entries and the lower value counts; at least 0.95 merges (tuned in T044, below). The instruction is versioned `rerank-v2`: "Are these two entries the same event, only written differently (another language, shorter, or with extra words)? Two different topics at the same time are different events."
- **Spike**: 20 to 30 ms warm, 1.1 s first call. It said yes to the truncated title (p 0.81) and to the Spanish/English budget pair, no to "Design review"/"Budget review" and to unrelated titles, and no to "Daily standup"/"Reunión diaria" given the titles alone (top log probabilities no -1.14, No -2.11, yes -2.42). With the same time written after each title it said yes (yes -0.18, no -5.49, p ≈ 0.95), so the query always carries the date and time of both sightings.
- **Tuning (T044, 2026-10-01)**: with the first instruction and a 0.5 threshold, `--models on` merged three pairs of different events (wrong-merge rate 0.12 against a target of 0.02): "Design review"/"Budget review" and "Project kickoff"/"Project sync" at the same time (yes 0.66 to 0.90 depending on order) and, among undated tasks, "Send the monthly invoice"/"Send the monthly report" (0.94 to 0.99). On the same pairs the translations and truncations score 0.97 to 1.00 in either order. Three changes, each measured on the synthetic set: the `rerank-v2` instruction (lowers the same-time different-topic pairs to 0.27 to 0.35 in the spike), asking both orders and keeping the lower probability (the model is order-sensitive: 0.66 against 0.89 for the same pair), and `rerankYes = 0.95`. Undated pairs are never judged: the model has only the titles and says yes to near-identical wording, so an undated pair in the uncertain band (text 0.7 to 0.9) becomes a possible duplicate. A known limit: two different events with near-identical titles at exactly the same start (for example "Sprint review" and "Sprint retrospective", both 0.99 in the probe) can still be merged; the user can split them and the split is remembered.
- **Alternatives**: the vision model as judge (6 GB loaded, seconds per call, would evict nothing but competes with analysis); asking the user for every uncertain pair (too many prompts; kept as the fallback through possible duplicates).

## R5. Candidates

- **Decision**: same context (a null context matches only null), same kind family (`appointment` alone; `task`, `reminder`, `deadline` together), and time: appointments on the same calendar day in the context's time zone with overlapping intervals or starts within 15 minutes, an all-day sighting matching any time that day; tasks with due dates within one day, or both undated. Statuses `active` and `dismissed`; not `merged`. Indexed by `(context_id, family, day)`.
- **Undated events**: an appointment with no resolved start has no day key and is matched like an undated task: same context, `text ≥ 0.9` to merge, never judged below `text` 0.7.
- **Rationale**: clarification 2. The day key also makes lookups cheap. Dismissed items are candidates so they act as tombstones (R8).

## R6. Title similarity

- **Decision**: normalise (Unicode case fold, strip accents, collapse spaces, drop punctuation and trailing `…`, `...`, `..`). Scores: equal → 1; one a prefix of the other at a word boundary or cut mid-word with the shorter at least 8 characters → 0.95 ("truncation"); otherwise the larger of normalised Levenshtein similarity and token Jaccard. Every alias of a candidate is compared and the best counts.
- **Rationale**: calendars cut titles at the block width, often mid-word; accents and case differ between apps.

## R7. Decision and thresholds

- **Decision**: `text = best title similarity`, `time = 1` for same start, 0.8 for overlap, 0.6 within 15 minutes, 0.5 for all-day against timed, 1 for both undated tasks. Rules, in order:
  0. on reanalysis, a finding whose normalised title and time equal a sighting this picture had before goes to that sighting's item (sticky, see R2), unless that item is merged away;
  1. a `keep_apart` pair between the candidate and the item this picture's earlier sighting belonged to blocks the candidate;
  2. `text ≥ 0.9` and `time ≥ 0.5` → merge;
  3. `time ≥ 0.8` (same or overlapping times) → uncertain, whatever the text: a translated title has low text similarity (cosine 0.856 for the standup pair in R3) and must still be judged;
  4. `text < 0.5` and (`cosine` unknown or `< 0.88`) → new;
  5. otherwise uncertain → reranker; yes ≥ 0.95 (lower of both orders) → merge; below → new; unavailable → new item plus a `possible_duplicates` row (FR-004).
  Undated tasks need `text ≥ 0.9` to merge; below 0.7 they are new, and between 0.7 and 0.9 they become a new item flagged as a possible duplicate without calling the reranker (R4, tuning). The best-scoring candidate wins; ties go to the most recently seen item. Two findings of the same picture are reconciled in order, so a duplicate inside one picture joins the item the first one made.
- **Rationale**: start values; the eval measures them, and the final numbers are written here and in ADR 0020 before the spec closes (SC-001, SC-002, SC-006). Without the models (`--models off`, and the app with both pickers on `None`), translated pairs end as possible duplicates rather than merges; the off-mode gate therefore scores merge recall on the cases without translations and requires every translated pair to be flagged (contracts/eval-cli.md).

## R8. Tombstones

- **Decision**: a dismissed item keeps its row (`status = dismissed`), titles and aliases, and stays a candidate. A sighting that matches it is attached and the item stays dismissed. Restore sets it back to `active`. Cleanup never removes a dismissed item.
- **Rationale**: one mechanism for "remember what was dismissed" and "restore with history"; FR-010.
- **Alternatives**: a separate tombstone table with fingerprints (duplicates the matching logic and loses history).

## R9. Fields and observations

- **Decision**: each sighting writes one observation per field it shows (`title`, `start`, `end`, `all_day`, `due`, `remind`, `people`, `place`, `notes`) with value, confidence, `inferred` (from the finding's provenance) and the capture time. A user edit writes an observation with `source = user` and a `field_locks` row. `FieldResolver` picks per field: locked user value; then read over inferred; then a full title over a truncation of it (FR-008) and a timed start or end over an all-day one (more specific, whatever the confidence); then higher confidence (differences under 0.1 count as equal); then more complete (a longer title that the other is a truncation of; a timed value over all-day); then the more recent capture. Titles not chosen go to `item_aliases`.
- **Rationale**: FR-006 to FR-009 and the spec's order; ties at near-equal confidence go to recency (User Story 2 scenario 3).

## R10. Operation log and undo

- **Decision**: `reconcile_ops` records, as one op per applied plan, the automatic merges of a capture (all its moved sightings listed inside), and one op for each manual merge, split, dismiss, restore, edit and unlock with the ids it touched and a JSON "before" state of those items (fields, status, locks, aliases, `merged_into`) and the list of sightings it moved. Undo of an operation moves those sightings back, restores the before state of fields that later operations did not change, recomputes the touched items, and records an `undo` op (itself undoable). An operation whose items were changed by a later operation that is not yet undone can still be undone for the sightings it moved; locks and status restore only when no later op touched them. Undo of an automatic merge writes `keep_apart`. `reconcile_op_items(op_id, item_id)` indexes which ops touched an item, for the History list and the dependency check. `Undo last` in the window targets the newest user op not yet undone; automatic merges are undone from an item's History.
- **Rationale**: clarification 1 (full history) and spec edge case "later sightings stay with the item they would now match".
- **Alternatives**: snapshots of the whole table (large); latest-only undo (rejected in clarification).

## R11. Cleanup

- **Decision**: sightings cascade with their picture. `CleanupService.delete` and the retention run then call `ItemStore.sweep()`, which recomputes items that lost sightings and deletes those left with none unless user-touched, locked or dismissed. Their log rows stay; undo of an op whose sightings are gone reports that it cannot be undone.
- **Rationale**: FR-014; recomputation needs Swift rules, so it cannot be a trigger.

## R12a. Context changes

- **Decision**: when the user picks another context for a picture (spec 004's picker, which only updates `image_context`), the picture is reconciled again: its sightings are planned against the new context's items and moved (or new items made), and items left empty are swept. The move is a `context` op (`by_user` 1 when the user picked the context), so it can be undone.
- **Rationale**: otherwise items keep the old context and later sightings from the right context make duplicates.

## R12b. Model memory

- **Check (2026-10-01)**: `qwen3-vl:8b-instruct` warm answered in 0.07 s before and after the embedding model and the reranker were loaded; loading them did not evict it. Not checked with `qwen3.8:27b-mlx` (18 GB); if eviction appears there, the judge is skipped when the vision model is not the only one that fits, and pairs go to possible duplicates.

## R12. Evaluation

- **Decision**: `memorri-eval reconcile [--cases eval/golden/synthetic-sequences] [--models off|on]` reads sequence cases (findings per capture plus the expected event of each finding, see [contracts/eval-cli.md](contracts/eval-cli.md)), runs the reconciler on an in-memory database, and reports pairwise merge recall (share of same-event finding pairs that ended in one item, SC-001), wrong-merge rate (share of items holding findings of two events, SC-002), reranker share (SC-006) and time per capture. `--models off` uses only text and time (deterministic, runs in `swift test`); `on` calls the local models. `memorri-eval run --reconcile` runs the 27 synthetic captures twice through the full pipeline and counts items against distinct events (SC-007). The generator `SyntheticSequences` writes truncations, view changes, translations, near-identical different meetings, recurring meetings on different days, contexts and dismissals.
- **Rationale**: the vision model is not needed to measure matching, and a deterministic set can gate every change (Constitution VI).

## Results (T044, T051, T052; 2026-10-01)

Measured on the tracked synthetic sequences (11 cases, 37 captures), the 27 synthetic pictures through the real pipeline (`qwen3-vl:8b-instruct`) and the Debug app with an isolated home. Thresholds are the ones in ADR 0020.

| Criterion | Evidence | Result |
|---|---|---|
| SC-001 merge recall at least 95% | `memorri-eval reconcile --models on`: 1.000 (translated pairs included). `--models off`: 1.000 on the pairs without translations, and every translated pair flagged as a possible duplicate | Met, on a set that was also used for tuning (ADR 0020) |
| SC-002 wrong merges at most 2% | Both modes: 0.000 of 28 (on) and 31 (off) items. Before tuning, `on` gave 0.12 (research R4) | Met |
| SC-003 a second analysis creates no item | `run --reconcile`, real model: after the second analysis 46 items, 0 of them new. Unit and sequence tests: `ReconcilerTests` (reanalysis), `ReconcileRunnerTests` | Met |
| SC-004 undo restores everything | `UndoTests`: snapshot equality of every item, observation, lock, alias, keep-apart and possible-duplicate row after undoing merge, split, edit, unlock, dismiss, restore, different, automatic merge and context change | Met |
| SC-005 user values and dismissals stick | Sequence cases `edited-title-stays` and `dismissed-stays-dismissed`: 0 overwritten titles, 0 recreated dismissals, in both modes | Met |
| SC-006 under 2 s per capture; judge for under 10% of pairs | 3.3 ms per capture off, 22 ms on (first call after loading the models about 150 ms in the app); 8.3% of compared pairs judged; a 250-finding capture among 5,000 items in 20 contexts plans in 0.3 s (`ReconcilerScaleTests`) | Met |
| SC-007 no more items than events; two actions to see a source | `run --reconcile`: 48 findings became 46 items for 46 expected events (the analysis found 8 unexpected findings and missed 6, see its report; reconciliation merged two across pictures). In the app: select a row, and the Sightings list shows date, time and display | Met |
| SC-008 a merge explains itself, every field shows its sightings | `ItemStoreTests` detail tests; the window's `why` line shows the stored rule and scores | Met |

Known gaps: the tuning set and the measuring set are the same invented sequences, so the figures are optimistic and should be rechecked on the first weeks of real use; two different events with near-identical titles at exactly the same start can be merged by the reranker (R4), and the user can split them; the small reranker is order-sensitive, which is why both orders are asked.

