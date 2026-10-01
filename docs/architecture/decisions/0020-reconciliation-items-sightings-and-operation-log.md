# 20. Reconciliation: items made of sightings, field observations and an operation log

- Status: Accepted
- Date: 2026-10-01
- Related: spec 005 (`specs/005-reconciliation/`), ADR 0014 (one pipeline, the model returns literal text), research R1 to R12

## Context and problem
Spec 004 stores findings per picture and replaces them on every reanalysis. The same meeting appears in many captures, views and languages, often with a truncated title. The constitution asks for one item per real event (III), evidence for every field (II), user edits and dismissals that stick (IV), and reversible merges. Matching must stay local and must never fail an analysis.

## Options considered
1. Merge findings in place (one findings row per event): simple, but loses per-capture evidence and cannot be undone.
2. Items with per-field observations, decided by an LLM for every pair: accurate, but seconds per pair with the vision model and no explanation of a merge.
3. Items made of sightings with per-field observations, decided by deterministic text and time scores, with embeddings as a feature and a small local reranker only for the uncertain band; every change written to an operation log with its before state.

## Decision
Option 3. A `reconcile` step after the analyse job plans the matches (async, may call the local embedding model and reranker) and applies them in one transaction that replaces the picture's earlier sightings, so reanalysis keeps item ids. Fields are resolved by user > read > inferred > confidence > completeness > recency. Dismissed items are kept as tombstones and still attract sightings. Splits and undone merges write keep-apart pairs. Every operation, automatic merges included, is undoable from the log with no time limit. Without the matching models, text and time decide and unclear pairs become possible duplicates for the user.

## Measured thresholds
`ReconcileThresholds.default` (research R7) is: merge when title similarity is at least 0.9 and time agreement at least 0.5; send to the judge when the times are the same or overlap (agreement 0.8 or more) or the titles are between 0.5 and 0.9 similar; new item below title similarity 0.5 unless the embedding cosine is 0.88 or more; the reranker's yes probability, the lower of both orders, must be at least 0.95; undated items merge at 0.9, are new below 0.7 and are flagged as possible duplicates in between, never judged.

On the 11 tracked synthetic sequences (37 captures, `memorri-eval reconcile`, 2026-10-01): without the matching models merge recall is 1.00 on the pairs without translations, every translated pair is flagged as a possible duplicate, wrong merges 0.00, 3 ms per capture. With the models merge recall is 1.00 including the translated pairs, wrong merges 0.00, 8% of compared pairs go to the reranker, 22 ms per capture. The first values (reranker threshold 0.5, one order, undated pairs judged) gave a wrong-merge rate of 0.12 and were changed for the reasons in research R4. The same set was used to tune and to measure, so these figures are optimistic; the set grows with what real use shows (revisit below).

## Consequences
- Easier: explaining and undoing any merge; spec 006 can show evidence per field; spec 008 can reprocess without duplicates.
- Harder: more tables and a sweep after cleanup; undo of an old operation can only be partial when later operations touched the same items.
- Revisit: the thresholds after the eval on the synthetic sequences and on the first weeks of real use; rescheduled meetings (spec 010) will need a link between items.
