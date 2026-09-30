# 15. The eval harness lives in the core package, with a synthetic golden set

- Status: Proposed
- Date: 2026-09-30
- Related: spec 004 (FR-019 to FR-024), Constitution VI, ADR 0002, ADR 0004

## Context and problem
Prompt and model changes must be measured. The harness must run the app's own pipeline, be runnable by a developer, compare runs and never put real screenshots in git. CLAUDE.md named `Tools/memorri-eval`, but SwiftPM refuses a target outside its package root (checked on 2026-09-30).

## Options considered
1. A separate package under `Tools/` depending on the core package by path.
2. An executable target inside `Packages/MemorriCore`, with the logic in a library folder `Evaluation/`.
3. Tests only, no command-line tool.

## Decision
Option 2: `Packages/MemorriCore/Sources/memorri-eval` (thin) over `MemorriCore/Evaluation` (tested), so the documented command `swift run --package-path Packages/MemorriCore memorri-eval` works. Golden cases are pictures with `meta.json` and `expected.json`; tracked cases are drawn by code (`generate-synthetic`) so their expected results are exact and nothing real is stored; real local cases stay ignored. Matching is one-to-one (same kind, titles 80% similar, time within 5 minutes). The tool refuses to run while the app's queue has a running job unless `--allow-busy` is given.

## Consequences
- `CLAUDE.md` and `DEVELOPER.md` change the path of the tool.
- Synthetic scores are an upper bound on real quality: drawn screens are cleaner. The report separates `synthetic` from `local` origin.
- The harness is part of the package build and tests.
