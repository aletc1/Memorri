# Spike report: structured answers with pictures on `qwen3.8:27b-mlx`

Spike S2 of spec 003 (tasks T001 to T003), run on 2026-09-30 on the developer Mac: Apple silicon, Ollama 0.34.4, `qwen3.8:27b-mlx` (27.8B, nvfp4, 18 GB, capabilities `completion`, `vision`, `tools`, `thinking`). Only a synthetic picture was used (a calendar-like grid with the texts "Team sync" and "10:00", drawn in code at each size); nothing from real sessions. The script, the driver and the raw results are in [`spike/`](spike/) so the run can be repeated on another model.

Each call: `POST /api/chat`, `stream: false`, `options.temperature` 0, no `keep_alive`, the picture as base64 JPEG (quality 0.9) and the test prompt with the test schema `{ description: string, contains_text: boolean, text_sample: string }` (all required, no extra keys). An answer counts as **valid** when it parses and matches the schema exactly, and as **correct** when `description` or `text_sample` mentions a known text.

## Findings in short

1. **The model honours a JSON schema with a picture attached.** With the server's own structured output (`format`), 50 of 50 answers were valid and correct, at every picture size and with thinking off and on.
2. **Describing the schema in the prompt instead does not work here.** Without `format`, only 8 of 30 answers were valid (0 of 15 with thinking on); the model mostly echoed the schema back. The fallback in ADR 0005 is therefore not needed and would not be reliable.
3. **The server does not accept HEIC pictures** (HTTP 400, `qwen3.5 does not support  input`). PNG and JPEG work. The stored analysis copies are HEIC (spec 002), so each one must be converted to JPEG before it is sent.
4. **Cost is almost entirely the picture.** A picture the server has not seen takes about 14 s at 2048 pixels with thinking off, and grows with the number of picture tokens. The answer itself takes 1 to 2 s. Identical repeated requests take 1 to 3 s because the server reuses its work on the prompt, so a retry of the same request is cheap.
5. **All `think` values are accepted, but `low`, `medium` and `high` behave like `true`.** The thinking text had about the same length for every value (270 to 400 characters). Leaving `think` out lets the model think by default, so `false` is what turns thinking off.

## Native structured output (`format`), thinking off

Time is the wall time of the call. **New picture** is the first call for a picture the server had not seen (what a real job costs); **repeat** is the median of the four identical calls that followed.

| Longer side | Picture tokens | Valid / correct | New picture | Repeat (median) |
|---|---|---|---|---|
| 1024 | 618 | 5 / 5 | 1.7 s | 1.4 s |
| 1536 | 1338 | 5 / 5 | 9.1 s | 2.0 s |
| 2048 | 2346 | 5 / 5 | 14.5 s | 1.7 s |
| 3072 | 5226 | 5 / 5 | 32.5 s | 2.2 s |
| 4096 | 9258 | 5 / 5 | 62.4 s | 3.0 s |

The first call of the session (model not in memory) at 1024 took 10.1 s in total, of which 3.5 s was loading the model.

## Native structured output, thinking on (`think: true`)

All 25 answers valid and correct. In the main matrix these calls reused pictures the thinking-off runs had already sent, so their times (3.5 to 5.1 s) show only the answer and not the picture. A separate check with pictures new to the server, at 2048 pixels, gives the real comparison:

| Setting | New picture, 2048 | Of which picture | Of which answer |
|---|---|---|---|
| thinking off | 14.3 s (3 runs, 14.26 to 14.39 s) | 12.6 s | 1.4 to 1.7 s (about 55 tokens) |
| thinking on | 16.5 s (3 runs, 16.33 to 16.59 s) | 12.6 s | 3.6 to 3.8 s (about 145 tokens) |

Thinking adds about 2.2 s and about 90 tokens per answer here, with no change in validity. The real extraction prompts (spec 004) produce much longer answers, so the gap will be larger there; the eval harness decides whether thinking pays for itself.

## Schema in the prompt, no `format` (the fallback), 3 runs per cell

| Thinking | Valid answers |
|---|---|
| off | 1024: 3 / 3; 1536: 2 / 3; 2048: 2 / 3; 3072: 0 / 3; 4096: 1 / 3 (3 + 2 + 2 + 0 + 1 = 8 of 15) |
| on | 0 / 15 (every answer was the schema echoed back, or not JSON) |

The fallback prompt was a single plain sentence added to the test prompt. A better prompt might do better, but there is no reason to spend effort on it: the native `format` was perfect.

## Which `think` values the model accepts

`none` (omitted), `false`, `true`, `"low"`, `"medium"` and `"high"` all returned HTTP 200 with a valid answer. Thinking text length: omitted 399, `true` 305, `low` 316, `medium` 399, `high` 399 characters. Levels therefore do not change the amount of thinking for this model, and omitting the field does not turn thinking off.

## The repair note

Not needed. No answer was invalid in native mode, so there was nothing to repair, and there is no evidence that a note helps. Because identical retries are cheap (finding 4), a retry resends the same request.

## Decisions

| Decision | Value | Reason |
|---|---|---|
| How structured answers are requested | The server's own `format` with the schema (ADR 0005 confirmed, fallback not used) | 50 / 50 valid and correct; the fallback gave 8 / 30 |
| Picture format sent | JPEG, quality 0.9, converted from the stored HEIC analysis copy | HEIC is rejected; JPEG is small (30 KB at 1024 pixels) |
| Default think level | `off` | Same validity; saves about 2 s per job here; revisit with the eval in spec 004 |
| `think` values sent | `off` sends `false`; `low`, `medium` and `high` send `true` for this model; a model without `thinking` gets no field | Levels behave like `true`; `ThinkWireValue.acceptsLevels(modelName:)` is true only for the GPT-OSS family |
| Default request timeout | 300 s | A new picture at 4096 pixels took 62 s; a long real answer at about 40 tokens per second, a model reload and slow moments need a wide margin. The allowed range stays 10 to 1800 s |
| Default analysis picture size | 2048 pixels (unchanged) | 14 s per new picture; 3072 costs 2.2 times as much and 4096 4.3 times as much. Spec 004 measures whether the extra detail pays for itself |
| Retry of an invalid answer | Resend the same request; no repair note | No invalid answers in native mode; repeats are cheap because the server reuses its work |
| Retry waits | Unchanged: 10 s, then 60 s | Nothing in the results argues for other values |

## What this does not show

- The synthetic picture has large clean text. Real screens have small text, so real answers will be longer and the cost of a picture at a given size is the same but the usefulness of each size is not known. Spec 004 settles that with real fixtures and the eval harness.
- Only one model was measured. A different model needs the same run (the script takes `--model`).
- Builds and tests ran on the Mac at times during the matrix. The picture-processing times match the token counts closely (about 185 tokens per second), so the effect looks small, but the figures are from a working machine, not a quiet one.
