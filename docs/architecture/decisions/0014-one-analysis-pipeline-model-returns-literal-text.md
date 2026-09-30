# 14. One analysis pipeline: the model returns literal text, code does the rest

- Status: Proposed
- Date: 2026-09-30
- Related: spec 004 (FR-005 to FR-013), ADR 0004, ADR 0005, ADR 0012, ADR 0013

## Context and problem
Extraction has parts a model is good at (seeing what kind of screen it is, finding the events and tasks, copying what is written) and parts it is bad at and that must be testable (date arithmetic across time zones, measuring a block's height, matching a context, checking that a citation exists). The app and the eval tool must run the same steps or the scores mean nothing.

## Options considered
1. Ask the model for final ISO dates, durations and context in one call.
2. A model call per concern (dates, durations, context).
3. The model returns the literal texts it sees and the numbered lines it cites; plain code resolves dates, geometry, tags and context.

## Decision
Option 3, behind one entry point, `AnalysisPipeline`, called by the queue job and by `memorri-eval`. Per picture: read the text (stored lines with boxes), call 1 classifies the screen and gives visual tags, call 2 extracts findings with a prompt and schema chosen by the kind, then code checks citations and resolves dates, durations, tags and context. Model answers use the native `format` (ADR 0013). Finished steps are stored so a retry resumes. Findings with invalid citations are discarded and recorded.

## Consequences
- Date, duration, tag and context rules are unit-tested tables; a wrong date is a code bug with a failing test, not a prompt lottery.
- Two model calls per picture; spike S2 measures the second call's cost and sets the message order.
- Prompts and schemas are versioned per kind; any change must pass the eval gate.
- The model cannot invent a box or an evidence crop: crops come from cited lines.
