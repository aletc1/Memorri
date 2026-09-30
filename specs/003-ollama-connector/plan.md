# Implementation Plan: Connect to the local model and run analysis jobs in the background

**Branch**: `003-ollama-connector` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-ollama-connector/spec.md`

## Summary

Give Memorri a reliable line to the local Ollama server and a safe way to use it. Settings gets a real Ollama section: server address (local addresses only), a health check with precise statuses, a model picker limited to vision-capable models read from the server, think level and request timeout. A spike on the real `qwen3.8:27b-mlx` first proves that it honours a JSON schema with a picture attached and measures time at several picture sizes; its report sets the defaults and the way structured answers are requested (ADR 0005, recorded in ADR 0013).

Work for the model goes through a durable, strictly serial queue kept in the local database: one job at a time, oldest first, retries with growing waits, waiting (not failing) while the server or model is unavailable, pause and resume, and progress as one line in the menu. In this spec the only jobs come from a **Test the model** button, which sends the newest stored analysis copy (or a synthetic built-in picture) with a fixed prompt and schema and records the attempt; captures are not queued automatically until extraction (spec 004). All network use sits in one loopback-only component (ADR 0011).

All logic (address rules, client, schema validation, status, queue, retry, menu text) lives in `MemorriCore` and is written test-first against a fake transport; the URLSession transport, the settings view and the menu are thin. See [research.md](research.md) for decisions and the spike design.

## Technical Context

**Language/Version**: Swift 6 (Swift 6.4 toolchain), strict concurrency

**Primary Dependencies**: Foundation `URLSession` (in one file only), GRDB 7.11.1 (already pinned), Core Graphics and Core Text for the built-in picture, SwiftUI/AppKit. No new third-party dependencies.

**Storage**: the existing SQLite database; migration `"v2"` adds `analysis_jobs` and `model_runs` ([data-model.md](data-model.md)). Settings in `UserDefaults`.

**Testing**: Swift Testing in `Packages/MemorriCore/Tests`: a fake `OllamaTransport`, a fake clock and sleeper, the real database in temporary directories, a `URLProtocol` stub for the real transport. `scripts/fake-ollama.py` (Python standard library) stands in for the server in the quickstart so failure cases are repeatable without touching the real model. The real model is used by the spike and by quickstart scenarios.

**Target Platform**: macOS 26+, Apple silicon. Ollama 0.34.4 with `qwen3.8:27b-mlx` (27.8B, nvfp4, 18 GB, vision and thinking) on this Mac.

**Project Type**: desktop-app (menu-bar agent) plus a local Swift package

**Performance Goals**: status within 5 s; model list within 3 s; menu and Settings respond within 1 s during a job (every request runs off the main actor); queue resumes within 35 s after the server returns.

**Constraints**: captured content goes only to a loopback address (FR-002, FR-019); strictly one job at a time; no job lost on quit or crash; a quit never costs an attempt; no notifications or alert windows; no automatic queueing of captures in this spec.

**Scale/Scope**: a handful of jobs at a time (test jobs); the queue is built for the later steady flow of one job per captured picture. Replies are small (a short JSON object) and stored as text.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | Addresses other than `localhost`, `127.0.0.1`, `::1` cannot be built (`LoopbackAddress`); one allow-listed network file that re-checks every request and refuses redirects (ADR 0011); no telemetry; test picture is synthetic. |
| II. Every item carries evidence | Pass (enabling) | Run records keep model, settings, prompt and schema versions, timing and the raw answer, which later items cite. No items yet. |
| III. Idempotent, no duplicates | Pass | One queue loop, jobs have ids, a quit does not repeat or lose work; nothing is created twice by a retry (an attempt writes its own run row, the job stays one). |
| IV. The User wins | Pass | Pause and resume, retry failed, clear finished are user actions; settings are never replaced silently (the chosen model is kept when it disappears). |
| V. Raw data kept, under user control | Pass | Raw answers are kept with their capture and expire with it under the existing retention and cleanup (clarification 1); no new hidden store. |
| VI. Test-first core, measured prompts | Pass | Every core type is test-first; the spike measures the model before defaults are set; the test prompt and schema are versioned (`test-v1`). The `memorri-eval` gate applies from spec 004, when real prompts exist. |
| VII. Incremental, always runnable | Pass | Ends with a runnable app that talks to the model and runs test jobs; extraction and sync untouched. |
| VIII. Decisions recorded | Pass | ADR 0011 (one loopback-only network component), ADR 0012 (durable serial queue), ADR 0013 (request defaults from the spike, written when the spike finishes); ADR 0005 is relied on and superseded only if the spike says so. |

Technical constraints check: Swift 6, macOS 26+, GRDB with migrations, Ollama with JSON-schema output (ADR 0005), unnotarized. The one constraint that needs a deliberate change is the no-network scan from spec 001, handled by ADR 0011. **Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/003-ollama-connector/
├── plan.md              # This file
├── research.md          # Decisions R1-R15 and the spike design
├── data-model.md        # Tables, states, settings
├── quickstart.md        # Validation scenarios
├── spike-report.md      # Written by the spike task (results and decisions)
├── contracts/
│   ├── core-interfaces.md   # MemorriCore protocols and types
│   └── ui-contract.md       # menu, Settings section, messages, log lines
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
scripts/
└── fake-ollama.py                          # stand-in server for the quickstart (new)
App/
├── AppEnvironment.swift                    # creates settings, service, queue; starts the loop (edit)
├── AppState.swift                          # analysis progress and line (edit)
├── MenuContent.swift                       # analysis line, Pause/Resume (edit)
└── Windows/
    ├── SettingsView.swift                  # Ollama section replaces the placeholder (edit)
    └── OllamaSettingsView.swift            # connection, model, thinking, timeout, test, queue (new)
Packages/MemorriCore/
├── Sources/MemorriCore/
│   ├── Inference/
│   │   ├── LoopbackAddress.swift           # the only way to name a server (new)
│   │   ├── OllamaTransport.swift           # protocol, request, response, errors (new)
│   │   ├── OllamaURLSessionTransport.swift # the one file allowed to use URLSession (new)
│   │   ├── OllamaClient.swift              # version, models, chat, request JSON (new)
│   │   ├── JSONValue.swift                 # values for schemas and answers (new)
│   │   ├── SchemaValidator.swift           # exact-schema check of answers (new)
│   │   ├── OllamaService.swift             # status, model list, default model (new)
│   │   ├── PictureConverter.swift          # HEIC/PNG to JPEG 0.9 for the server (new)
│   │   └── SamplePicture.swift             # built-in synthetic picture (new)
│   ├── Analysis/
│   │   ├── AnalysisJobStore.swift          # records, protocol, GRDB store (new)
│   │   ├── StoredPictureProvider.swift     # reads the stored analysis copy for a job (new)
│   │   ├── AnalysisQueue.swift             # the serial loop, retry policy, progress (new)
│   │   ├── AnalysisLine.swift              # menu texts (new)
│   │   ├── ModelTestJob.swift              # prompt, schema, runner (new)
│   │   └── ModelTestResultLine.swift       # the result line under Test the model (new)
│   ├── Settings/
│   │   └── OllamaSettings.swift            # address, model, think, timeout, paused (new)
│   └── Storage/
│       └── Migrations.swift                # adds "v2" (edit)
└── Tests/MemorriCoreTests/                 # one test file per new type above; NoNetworkTests updated
docs/architecture/decisions/                # 0011, 0012 (proposed now), 0013 (from the spike)
```

**Structure Decision**: same two-part layout as specs 001 and 002. The queue, service and client depend only on protocols (`OllamaTransport`, `AnalysisJobStoring`, `AnalysisJobRunning`, `TimeSource`, `QueueSleeping`), so every branch (server down, slow, invalid answer, quit mid-job, pause) is unit-tested with fakes; `OllamaURLSessionTransport`, `OllamaService.live(settings:)` and the views are the only parts that need the real system, covered by the spike and the quickstart.

## Complexity Tracking

No constitution violations. One deliberate relaxation: the no-network source scan becomes an allow-list of exactly one file (ADR 0011). A small Python stand-in server is added for repeatable failure testing; it is a development script, not shipped.
