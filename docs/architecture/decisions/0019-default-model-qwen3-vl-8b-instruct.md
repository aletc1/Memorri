# 19. The default model is `qwen3-vl:8b-instruct`

- Status: Accepted
- Date: 2026-10-01
- Related: spec 004, ADR 0005, ADR 0013, ADR 0014, ADR 0017, `specs/004-ocr-extraction-and-eval/research.md`

## Context and problem
Spec 003 chose `qwen3.8:27b-mlx` as the recommended model. It reads a picture in 20 to 25 seconds, sometimes much more, and 34 GB of memory stay loaded while it works. Analysis is the slow step of the app, and the user asked for a lighter model that does the same job. With the reading done by OCR and dates resolved in code (ADR 0014), the model only classifies a picture and structures text, which small instruction-following models can do.

## Options considered
All on the 27 synthetic golden cases, think off, picture size 2048, the same pipeline. Cells are findings precision / recall / field accuracy, then seconds per picture.
| Model | Prompt | Result | Remark |
|---|---|---|---|
| `qwen3.8:27b-mlx` (18 GB) | v4 (before the real-capture changes) | 0.90 / 0.96 / 0.94, 24 s | the previous baseline |
| `qwen3.8:27b-mlx` | v10 | 0.89 / 0.89 / 0.98, 21 s | after the prompt rewrite |
| `qwen3-vl:8b-instruct` (6 GB) | v12 | 0.83 / 0.87 / 0.90, 9 s (v9 to v12 gave the same) | chosen |
| `gemma4` (6.6 GB) | v8 | 0.75 / 0.78 / 0.92, 5 s | no gain from the v9 prompt; one case looped |
| `qwen3-vl:8b` (thinking) | v8 | 0.79 / 0.65 / 0.92, 37 s | the server ignores `think: false` for it; 8 of 27 cases ended without an answer |
| `minicpm-v4.5` (6.1 GB) | v8 | 0.57 / 0.70 / 0.89, 7 s | many extra items, two failures |

On calendar day, week and month pictures the 8B instruct model equals the 27B one. Its remaining gap is in email (0.40 / 0.40 against 0.60 / 0.60) and in field accuracy on documents. The prompts were tuned on these same cases, so the numbers are a little optimistic for real captures.

## Decision
`OllamaSettings.recommendedModel` is `qwen3-vl:8b-instruct`, with prompts `extract-<kind>-v12` (numbered rules, a field contract and short examples for pictures whose dates are written in text) and `classify-v2`. A model the user chose keeps being used: the default is applied only when none is chosen. `qwen3.8:27b-mlx` remains a supported choice for the most accurate results.

## Consequences
- First analysis is about 2.3 times faster and needs a quarter of the memory.
- Email is the weakest screen kind; the model sometimes reads the message list beside the open message. A sharper rule for this, a text-only second opinion, or more tuning with real emails are the follow-ups.
- The answer length is capped (`num_predict`, 3072 tokens and up, more for a model that thinks) so a model that falls into a loop fails in seconds instead of at the 300 second timeout.
- A model that cannot switch thinking off (`qwen3-vl:8b`, the thinking variant) is slow and unreliable here; the instruct variant is the one to use.
