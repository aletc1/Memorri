# Golden set

Fixtures for `memorri-eval` (see `specs/004-ocr-extraction-and-eval/contracts/eval-cli.md`). Each case is a directory:

```
case-name/
  screenshot.png     # the picture
  meta.json          # capture time, the Mac's time zone, context, windows, display size and scale, origin
  expected.json      # screen kind, tags, context, drawn lines and the findings a person would make
```

- `synthetic/` holds 27 cases drawn by the program itself (calendar week, day and month views, email, chat, documents and pictures with nothing to find, in English and Spanish, 12 and 24 hour clocks, with and without a remote desktop frame). They contain no real data and are tracked. Do not edit them by hand: change `Packages/MemorriCore/Sources/MemorriCore/Evaluation/Synthetic*.swift` and regenerate with
  `swift run --package-path Packages/MemorriCore memorri-eval generate-synthetic`. The same code always writes the same bytes, so `git status` shows a change only when a drawing or an expected answer changed.
- Everything else under `eval/golden/` (your own cases with `"origin": "local"`) stays on this Mac and is git-ignored. Real screenshots and real model answers are never committed.
- Reports go to `eval/out/` (git-ignored). A report made from local cases is never written under `synthetic/`.

## Sequence cases (spec 005)

`synthetic-sequences/<case>/sequence.json` holds findings per capture, written by the program, and the real-world event each finding stands for. `memorri-eval reconcile` runs them through the reconciler and scores merges (see `specs/005-reconciliation/contracts/eval-cli.md`). They contain only invented titles and are tracked; regenerate with `swift run --package-path Packages/MemorriCore memorri-eval generate-sequences`.
