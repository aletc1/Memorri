# Eval CLI additions: reconciliation

Extends [spec 004's `memorri-eval`](../../004-ocr-extraction-and-eval/contracts/eval-cli.md).

## Commands

| Command | What it does |
|---|---|
| `generate-sequences [--out eval/golden/synthetic-sequences]` | Writes the tracked synthetic sequence cases (same files every time). |
| `reconcile [--cases eval/golden/synthetic-sequences] [--models off\|on] [--embedding-model <name>] [--reranker-model <name>] [--address http://localhost:11434] [--out eval/out/<name>.json] [--only <case>]` | Reconciles each case into a fresh in-memory database and scores it. `off` (default) uses text and time only and needs no server. |
| `run … --reconcile` | After analysing every case, reconciles the results, then analyses and reconciles them a second time; reports items found, distinct expected events and items created by the second pass (SC-003, SC-007). |
| `compare <a.json> <b.json>` | Also compares reconcile reports. |

Exit codes as in spec 004; `--min-merge-recall <x>` and `--max-wrong-merge <x>` make `reconcile` exit 3 below or above them.

## Sequence case format

```text
eval/golden/<set>/<case>/sequence.json
```

```json
{
  "macTimezone": "Europe/Madrid",
  "contexts": [{ "id": "A", "name": "Customer A", "timezone": "Europe/Madrid" }],
  "captures": [
    { "id": "c1", "capturedAt": "2026-10-13T08:00:00Z", "context": "A",
      "findings": [
        { "event": "standup-tue", "kind": "appointment", "title": "Daily standup",
          "start": "2026-10-14T07:00:00Z", "end": "2026-10-14T07:15:00Z", "allDay": false,
          "inferred": ["end"], "confidence": 0.8 } ] } ],
  "actions": [ { "after": "c2", "action": "dismiss", "event": "standup-tue" } ]
}
```

- `event` is the expected real-world event; findings with the same `event` should end in one item, different events in different items.
- `actions` (optional) apply user operations by event after a capture, as `{after, action, event, title?}`: `dismiss`, `restore`, `editTitle` (with `title`), `split` (the newest sighting of the event). Expectations then follow the spec (a dismissed event is not recreated; an edited title stays).

## Report

Per case and overall:
- `mergeRecall`: same-event finding pairs that ended in the same item / all same-event pairs (SC-001, target ≥ 0.95 with `--models on`). With `--models off` it is computed without the translation cases, which are reported as `translatedFlagged` (share of translated pairs left as possible duplicates, target 1.0).
- `wrongMergeRate`: items holding findings of more than one event / items (SC-002, target ≤ 0.02).
- `translatedFlagged`: translated pairs (the two sightings written in different languages, `lang` on the finding) that ended merged or as a possible duplicate / all translated pairs (target 1.0 with `--models off`).
- `judgedShare`: compared pairs sent to the reranker / compared pairs (SC-006, target < 0.10).
- `msPerCapture`: mean reconciliation time per capture (SC-006, target < 2000 without reranker calls).
- `recreatedDismissed` and `overwrittenTitles`: dismissed events that came back active, user titles overwritten (SC-005, target 0).
- Lists per case: `missedMerges` (pairs of finding titles), `wrongMerges` (item title and its events). The report type is `SequenceReport` (the name `ReconcileReport` was taken by the capture-file reconciliation of spec 002).
- `run --reconcile` prints, per case, findings against items and the items the second analysis created (`ReanalysisReport`).

## Synthetic set (tracked)

Written by `SyntheticSequences` and covering: truncated titles cut mid-word and at a word; the same meeting in month, week and email views with and without end time; English and Spanish titles of one meeting; accents and case; two different meetings at the same time with a shared word; a recurring meeting on five days; the same title and time in two contexts; an all-day and a timed sighting of one event; undated tasks with near titles; a dismissal followed by more sightings; a title edit followed by more sightings; the same picture twice.
