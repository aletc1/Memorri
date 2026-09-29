# Memorri Constitution

## Core Principles

### I. Local-First and Private
All customer data stays on this Mac. Ollama is reached on localhost only. There is no telemetry, no cloud inference, and no third-party network call that carries captured content. Real screenshots are never committed to git.

### II. Every Item Carries Evidence
Every inferred appointment, task or reminder records where each field came from: the capture, the OCR lines, a cropped evidence image, and a confidence value. Values the model guessed (for example a default 1h duration) are flagged as inferred so later observations can overwrite them.

### III. Idempotent, No Duplicates
Reprocessing a capture never creates duplicate items. Partial or truncated observations of the same real-world event resolve to one entity. Merging is reversible.

### IV. The User Wins
A field the user edits is locked and never overwritten by inference. A dismissed item is tombstoned and never recreated. Nothing below the confidence threshold syncs without the user's approval.

### V. Raw Data Is Kept, Under User Control
Captures, OCR output and raw model responses are stored so decisions can be re-assessed and items re-derived. Storage use is visible, and the user can apply a retention policy or purge from Settings.

### VI. Test-First Core, Measured Prompts (NON-NEGOTIABLE)
Logic in `MemorriCore` is written test-first and covered by `swift test`. Any prompt, schema or model change must pass the `memorri-eval` harness against the golden set without regressing precision or recall.

### VII. Incremental, Always Runnable
Each spec ships a runnable, testable app. EventKit sync is the last capability built. Features are not started before the ones they depend on are verified.

### VIII. Decisions Are Recorded
Architecture decisions are written as ADRs in `docs/architecture/decisions/`. Incidents and wrong assumptions that do not fit a spec are written as postmortems in `docs/postmortems/`. Specs link the ADRs they rely on.

## Technical Constraints
- Native Swift 6 app for macOS 26+, using SwiftUI and AppKit. The project is generated with XcodeGen.
- Persistence is SQLite through GRDB.swift, with schema migrations and FTS5 for search.
- Extraction combines Apple Vision OCR with a vision-language model served by Ollama, using JSON-schema-constrained output.
- macOS Calendar and Reminders integration goes through EventKit, one-way from Memorri to the system.
- The app is not distributed or notarized. It is signed locally with a stable self-signed identity so macOS permissions survive rebuilds.

## Development Workflow
- Work follows Spec Kit: specify, clarify, plan, tasks, analyze, implement. Each feature has its own branch and `specs/NNN-name/` directory.
- Commits use English Conventional Commits.
- A spec is done only when its acceptance scenarios pass in the running app or in the eval harness.

## Governance
This constitution supersedes other practices. Amendments require a version bump and a note in the relevant ADR. Complexity beyond these principles must be justified in the plan. `CLAUDE.md` holds runtime guidance for the coding agent.

**Version**: 1.0.0 | **Ratified**: 2026-09-29 | **Last Amended**: 2026-09-29
