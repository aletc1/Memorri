# feat(reconciliation): one list of items without duplicates (spec 005)

Spec: [`specs/005-reconciliation/`](specs/005-reconciliation/spec.md). ADR: [0020](docs/architecture/decisions/0020-reconciliation-items-sightings-and-operation-log.md) (accepted here). Roadmap: 005 is Done.

## What changed and why

Spec 004 stored findings per picture, so the same meeting showed up once per capture, view and language. Now a `reconcile` step after the analyse job turns every finding into a **sighting** of an **item** (one real appointment, task or reminder):

- **Matching** (`Reconciliation/`): candidates share the context, the kind family and the day; scores come from normalised title similarity (truncation aware), time agreement and, when installed, the local e5 embeddings. Clear matches merge, clear misses become new items, and the band in between goes to the local Qwen3 reranker. Without the models, unclear pairs become new items flagged as **possible duplicates**; no capture ever fails because of reconciliation.
- **Idempotent**: planning is async, applying is one transaction that replaces the picture's earlier sightings, so a reanalysis keeps the item ids.
- **Fields and evidence**: every field keeps all its observations (user > read > inferred > confidence > completeness > recency); every sighting stores why it joined its item (rule and scores).
- **The user wins**: edits become locked user values, dismissed items stay as tombstones and still attract sightings, a split remembers `keep_apart`.
- **Operation log and undo** with no time limit: automatic merges, merge, split, dismiss, restore, edit, unlock, mark different and context changes can all be undone, newest first or alone.
- **Cleanup** sweeps items after captures are deleted; edited, locked and dismissed items stay.
- **Items window** (menu → `Items…`): filters, list with badges, detail with fields, sightings, History and per-operation Undo, merge, split, dismiss, restore, lock-choice sheet. Settings → Ollama gets a `Matching models` group.
- **Eval**: `memorri-eval generate-sequences`, `reconcile [--models off|on]`, `run --reconcile`, `compare` for both, and a tracked synthetic set (`eval/golden/synthetic-sequences/`, invented titles only).

## How it was verified

- `swift test --package-path Packages/MemorriCore`: 937 tests pass, including the off-mode gate on the tracked sequences, undo snapshot equality, and a scale test (a 250-finding capture among 5,000 items in 20 contexts plans in 0.3 s).
- `memorri-eval reconcile` (12 cases, 40 captures): `--models on` merge recall 1.000, wrong merges 0.000, 4.1% of pairs judged, 25 ms per capture; `--models off` recall 1.000 without translations, translated pairs flagged 1.00, wrong merges 0.000, 3 ms.
- `memorri-eval run --reconcile` with `qwen3-vl:8b-instruct` on the 27 synthetic pictures: 48 findings became 46 items; the second analysis created 0 items. The two cross-picture joins are the English and Spanish agendas of the same two events (checked by hand against `expected.json`). The cases hold 44 distinct events, so SC-007 is **not met on real model output** (46 items): the analysis found 8 unexpected findings and missed 6 (spec 004's precision 0.83, recall 0.87), which reconciliation cannot undo. Fed the expected findings, the same run gives 43 items; the one over-merge is "Quedar"/"Sync", two independently drawn cases at the same hour.
- The Debug app with an isolated home: the same picture ingested twice gave one item with `2 sightings` and `created=0` in the log; Dismiss and Undo last worked in the Items window. Scenarios that need typing or Settings clicks are covered by tests instead (see the quickstart results). Success criteria table: `research.md`, Results.
- Clean Debug and Release builds without warnings of ours; the Release binary has no debug ingest switches.

## What to look at

- **Thresholds** (`ReconcileThresholds`) and the reranker use. The first values gave a wrong-merge rate of 0.12 with the models on, so the reranker needs yes ≥ 0.95 in both orders (instruction `rerank-v2`), undated pairs are flagged instead of judged, and findings of one picture are never judged against a candidate another finding of that picture took. Reasoning and the spike numbers are in research R4 and R7. I added same-start different meetings to the set after a review pointed out it had none; they broke the first version of the rules (wrong merges 0.062) before the same-picture rule fixed them.
- The tuning and measuring sets are the same invented sequences, so the numbers are optimistic. Two captures that show two different events with near-identical titles at exactly the same start (never together in one picture) can still merge, like "Quedar"/"Sync" above; a split fixes it and is remembered.
- Findings stored before this spec are not reconciled until their capture is analysed again (clarification 4).
- `SequenceReport` is named so because `ReconcileReport` already exists for the capture-file reconciliation of spec 002.

## Known gaps

- Undo of a redone split cannot recreate the `keep_apart` pair.
- Evidence crops and inline editing of every field belong to spec 006; the Items window here is the minimal one.
