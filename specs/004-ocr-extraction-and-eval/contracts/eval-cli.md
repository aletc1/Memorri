# Eval CLI: `memorri-eval`

Runs the same `AnalysisPipeline` the app runs over golden cases and scores the result. Executable target `memorri-eval` in `Packages/MemorriCore` (research R14).

```bash
swift run --package-path Packages/MemorriCore memorri-eval <command> [options]
```

## Commands

| Command | What it does |
|---|---|
| `generate-synthetic [--out eval/golden/synthetic]` | Draws the synthetic cases (same files every time). |
| `run [--cases eval/golden] [--out eval/out/<name>.json] [--size 2048] [--model <name>] [--think off\|low\|medium\|high] [--address http://localhost:11434] [--only <case>] [--replay <report.json>] [--allow-busy]` | Runs every case (or one), prints the report, saves the JSON. `--replay` re-scores the stored model answers without calling the model. |
| `compare <a.json> <b.json>` | Prints the difference in every measure and the cases that changed. |
| `sweep-size [--cases …] [--sizes 1024,1536,2048,3072]` | Runs the set at each size and prints measures and mean seconds per picture; recommends a default (research R18). |

Exit code 0 when the run finished (scores are information, not pass or fail), 2 for a refusal (app busy, server unreachable, no cases), 1 for an error. `--min-recall <x>` and `--min-precision <x>` make `run` exit 3 when a score is below them, for use as a gate.

## Refusals

- The app's queue has a running job: `Pause analysis in Memorri first (or use --allow-busy).` (research R15).
- The server is unreachable or no vision model is chosen or installed: the status text from spec 003, and nothing is scored.
- The address is not local: rejected exactly as in the app (`LoopbackAddress`).

## Golden case format

```text
eval/golden/<set>/<case>/
  screenshot.png     # full-resolution picture
  meta.json
  expected.json
```

`meta.json`:
```json
{ "capturedAt": "2026-10-14T23:40:00Z", "macTimezone": "Europe/Madrid",
  "context": { "name": "Customer A", "timezone": "America/New_York", "hints": [{"kind": "app", "value": "Outlook"}] },
  "windows": [{"app": "Microsoft Outlook", "bundleID": "com.microsoft.Outlook", "title": "Calendar - Customer A", "frame": [0,0,1600,1000]}],
  "displaySize": [1600, 1000], "scale": 1.0, "origin": "synthetic" }
```
`context` and `windows` are optional. `origin` is `synthetic` or `local`.

`expected.json`:
```json
{ "screenKind": "calendar_week",
  "tags": [{"key": "application", "value": "Outlook"}, {"key": "clock_style", "value": "24h"}],
  "context": "Customer A",
  "findings": [
    { "kind": "appointment", "title": "Team sync", "start": "2026-10-14T10:00:00-04:00", "end": "2026-10-14T11:30:00-04:00",
      "allDay": false, "people": [], "place": null,
      "inferred": ["end"] } ] }
```
`tags` and `context` are optional. `inferred` lists the fields that the pipeline should flag as inferred. Times carry their offset.

Only `synthetic/` cases are tracked; everything else under `eval/golden/` and everything under `eval/out/` is git-ignored (already so since spec 001).

## Matching and metrics

- One-to-one matching by best score. A found finding matches an expected one when: same kind; titles at least 80% similar after lowercasing and removing spaces and punctuation (normalised edit distance), or one contains the other; start (or due, for tasks and deadlines) within 5 minutes. Thresholds are printed and saved in every report.
- Precision = matched / found. Recall = matched / expected. Field accuracy = equal fields / compared fields over matched findings: `start`, `end`, `allDay`, `due`, `remind`, `people` (as a set), `place` (normalised), and `inferred` flags (a field flagged when expected, not flagged when not).
- Classification accuracy = cases whose kind equals `screenKind`. Tag accuracy per key = cases with that expected tag where the stored tag has the same value (case-insensitive), plus the count of wrong and missing tags. Context accuracy when `context` is expected.
- Also printed: results by screen kind, by `origin`, and by confidence band (below 0.6, 0.6 to 0.85, above), the mean seconds per case, and for every case the list of missed findings, unexpected findings (with the closest expected one) and disagreements between the model's title and its cited lines' text.

## Report (JSON)

```json
{ "version": 1, "createdAt": "…", "settings": {"model": "…", "size": 2048, "think": "off", "promptVersions": {"classify": "classify-v1", "calendar_week": "extract-calendar_week-v1"}, "thresholds": {"titleSimilarity": 0.8, "minutes": 5}},
  "ranWhileAppBusy": false, "overall": {"precision": 0, "recall": 0, "fieldAccuracy": 0, "classificationAccuracy": 0, "meanSeconds": 0},
  "byKind": {}, "byOrigin": {}, "tagAccuracy": {}, "cases": [ { "name": "…", "origin": "synthetic", "precision": 0, "recall": 0, "fieldAccuracy": 0,
      "kind": {"expected": "…", "found": "…"}, "missed": [], "unexpected": [], "steps": [ {"step": "classify", "request": "…", "rawAnswer": "…", "durationMs": 0} ] } ] }
```
Reports contain model answers about the pictures of the cases; reports of `local` cases stay in `eval/out/` (ignored).

## Text output (example)

```
memorri-eval  model qwen3.8:27b-mlx  size 2048  think off  (titles ≥ 0.80, ±5 min)
cases 26  (synthetic 26, local 0)   mean 34.2 s/case
findings   precision 0.91  recall 0.88  field accuracy 0.94
kind       accuracy 0.96   calendar_week 1.00 … chat 0.88
tags       application 0.92  clock_style 1.00 …
missed     calendar_week-03: "Design review" (nearest found: none)
unexpected email-02: "Budget" (nearest expected: none)
```
