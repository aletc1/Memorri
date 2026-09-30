# 17. The default analysis picture size stays at 2048

- Status: Accepted
- Date: 2026-09-30
- Related: spec 004 (US9, FR-032), ADR 0004, ADR 0014, `specs/004-ocr-extraction-and-eval/spike-report.md`

## Context and problem
The copy of a capture that goes to the model (the long edge set in Settings → Storage) has a default of 2048 pixels, chosen in spec 002 before anything was measured. A smaller picture is faster and uses less of the model's context; a larger one may read small text better. Spec 004 has a harness that scores the whole pipeline, so the default can be chosen from evidence.

## Options considered
1. Keep 2048.
2. Lower the default to 1536 or 1024 if the scores hold.
3. Raise it to 3072.

## Decision
Option 1. `memorri-eval sweep-size` ran the 27 synthetic cases at four sizes with `qwen3.8:27b-mlx`, think off, prompts `classify-v2` and `extract-<kind>-v4`. The rule (research R18) picks the smallest size whose findings F1 and field accuracy are each within 0.02 of the best:

| Size | Precision | Recall | F1 | Field accuracy | Mean seconds per picture |
|---|---|---|---|---|---|
| 1024 | 0.84 | 0.89 | 0.86 | 0.96 | 16.7 |
| 1536 | 0.82 | 0.87 | 0.84 | 0.94 | 21.2 |
| 2048 | 0.90 | 0.96 | 0.93 | 0.94 | 22.1 |
| 3072 | 0.90 | 0.96 | 0.93 | 0.94 | 22.1 |

No size below 2048 is within 0.02 of the best F1 (1536 loses 0.09, 1024 loses 0.07), so 2048 stays. A size never enlarges a picture, and the synthetic pictures are 1600 pixels wide, so 2048 and 3072 give the same copy and the same numbers: this sweep says nothing about whether 3072 would help on a real 3440-pixel screen. 1024 is 25% faster and has the best field accuracy (0.96), but it misses about one finding in ten more.

## Consequences
- No code change; the default in `StorageSettings` is unchanged and a user's own value is kept as before.
- Revisit with real captures: add local cases of the user's own large displays (gitignored) and run the sweep again, which is the only way to compare 2048 with 3072 and to see whether the small text of a remote session needs more than 1024 pixels.
- The one-time cost is paid by the model's time, not by the reading, which always uses the full-resolution picture.
