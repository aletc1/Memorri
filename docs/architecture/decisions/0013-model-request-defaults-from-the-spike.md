# 13. How the app asks the model: request format and defaults from the spike

- Status: Proposed
- Date: 2026-09-30
- Related: spec 003 (FR-008 to FR-010, FR-018, `specs/003-ollama-connector/spike-report.md`), ADR 0005, ADR 0004

## Context and problem
ADR 0005 chose structured answers through the server's JSON-schema `format`, with a fallback (schema in the prompt, then validate and repair) if the model did not honour it with pictures attached. The spike on `qwen3.8:27b-mlx` measured both, the accepted picture formats and `think` values, and the cost per picture size.

## Options considered
1. Native `format` with the schema: 50 of 50 valid and correct answers across five picture sizes, thinking off and on.
2. Schema described in the prompt, no `format`, then validate and repair: 8 of 30 valid (0 of 15 with thinking on), because the model echoed the schema back.
3. Send the stored HEIC analysis copy as it is: rejected by the server (HTTP 400).

## Decision
- Use the server's own `format` with the schema (option 1). ADR 0005 stands; its fallback is not built. Answers are still validated against the schema, and a mismatch is a failed attempt.
- Convert each stored HEIC analysis copy to JPEG (quality 0.9) before sending; the stored copy does not change.
- Defaults: think level `off`; request timeout 300 s; analysis picture size 2048. `off` sends `think: false`; `low`, `medium` and `high` send `true` for models that only take a boolean (levels behave like `true`), and a level string only for the GPT-OSS family; a model without the `thinking` capability gets no `think` field.
- A retry after an invalid or failed answer resends the same request, with no repair note.

## Consequences
- A new picture costs about 14 s at 2048 pixels (12.6 s of it is processing the picture), 32 s at 3072 and 62 s at 4096; raising the analysis size is a real cost that spec 004 must justify with the eval.
- If another model is chosen that does not honour `format`, the fallback has to be designed then; the `useNativeFormat` flag on the request exists for that case.
- The defaults are starting points from a synthetic picture; spec 004 may change the think level and the picture size after measuring on real fixtures, with a new ADR if they change.
