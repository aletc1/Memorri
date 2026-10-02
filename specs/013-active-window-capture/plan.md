# Implementation Plan: Capture only the active window

**Branch**: `013-active-window-capture` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/013-active-window-capture/spec.md`

**ADR**: [0028](../../docs/architecture/decisions/0028-window-capture-and-outline.md) (Proposed), building on 0008, 0009, 0016, 0022

## Summary

A second global shortcut ("Capture window", default Control+Option+Command+W) and a menu item take one picture of the active window: the screen's pixels inside the window's outline, so anything drawn over the window is included and nothing hidden is recovered (Q1 B). The picture is stored like one display of a full-screen capture, with the capture event marked `scope = window` and one recorded window that fills the picture. The analysis reads it as one chosen window: the windows call still runs to decide the kind of view, but its relevance answer is overridden to "relevant" (FR-015), the reference clock looks only inside the window and never flags a missing clock (FR-016), and the window's name reaches the sighting and the evidence through a normal window reading. Findings reconcile with everything else unchanged. After the capture is stored, a click-through red outline window is drawn on each display the window touches and fades after about a second. The full-screen path (`run(trigger:)`, `captureAllDisplays`, the analysis of a capture whose scope is not window) is not edited, only extended beside.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), macOS 26+

**Primary Dependencies**: ScreenCaptureKit (display filter with a source rectangle, or rectangle capture across displays), AppKit (`NSWorkspace`, a borderless panel for the outline), KeyboardShortcuts (already pinned, one more name), GRDB, the existing Ollama connector. No new package. No Accessibility permission (research R2).

**Storage**: SQLite: one migration adds `capture_events.scope` and `capture_images.desktop_frame_json`. Picture files use the existing layout (ADR 0009).

**Testing**: `swift test --package-path Packages/MemorriCore` (Swift Testing). Pure logic in the core package, test-first: picking the window, outline geometry, the clock rule, queue and busy rules, scope storage. `memorri-eval run` with new synthetic window-capture cases. Manual run for the outline and the shortcut (there is no App test target).

**Target Platform**: macOS 26+ menu-bar app

**Project Type**: desktop app with a local core package and an eval CLI

**Performance Goals**: outline visible within half a second of the press (SC-002); a window capture costs one windows call plus one extraction (a month grid needs none); no change to the full-screen path

**Constraints**: local only (constitution I); no prompt text change (VI: the windows prompt and schema stay; the relevance override is code, tested); existing full-screen tests and eval scores unchanged (FR-019); window names never logged

**Scale/Scope**: one picture per press; a window may fill a display or span displays

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I. Local-first and private | Pass | Picture, app name and title stay on the Mac; titles never logged (FR-009, FR-022). The outline window is excluded from sharing. |
| II. Every item carries evidence | Pass | The chosen window gets a window reading, so sightings and evidence carry its name; cut-outs come from the window picture (FR-018). |
| III. Idempotent, no duplicates | Pass | Findings reconcile through the unchanged reconciler; the same event in a window capture and a full-screen capture is one item (FR-017). |
| IV. The user wins | Pass | No change to locks, tombstones or review. |
| V. Raw data kept | Pass | Picture, OCR and model runs are stored as for any capture; removed by retention and "Delete everything". |
| VI. Test-first, measured prompts | Pass | No prompt or schema change. New eval cases cover window captures; the 33 existing cases must score the same before and after. Pure logic is written test-first. |
| VII. Incremental, always runnable | Pass | Independent of 009 and 010 in code; the migration is `v13`, after 009 and 010 (R9). |
| VIII. Decisions recorded | Pass | ADR 0028. |

Post-design re-check: unchanged, all pass.

## Project Structure

### Documentation (this feature)

```text
specs/013-active-window-capture/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── core-interfaces.md
│   └── app-and-eval.md
├── checklists/requirements.md
└── tasks.md            # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/MemorriCore/Sources/MemorriCore/
├── Capture/
│   ├── WindowCapturing.swift         # new: protocol, WindowCaptureResult, WindowCaptureFailure
│   ├── ActiveWindowPicker.swift      # new: pure choice of the window from the front-to-back list
│   ├── CaptureOutline.swift          # new: pure outline geometry per display, CaptureOutlining protocol
│   ├── CapturePipeline.swift         # + runWindow(trigger:); run(trigger:) untouched
│   ├── CaptureRequestService.swift   # + requestWindow(_:), one shared debounce and busy rule
│   ├── CaptureOutcome.swift          # + .windowComplete(app:), .noWindow(reason)
│   ├── LastCaptureLine.swift         # + window line
│   └── PictureIngest.swift           # + scope for debug ingest and eval
├── Storage/
│   ├── Migrations.swift              # + scope, desktop_frame_json
│   └── CaptureStore.swift            # scope and desktop frame on the records
├── Extraction/
│   └── AnalysisPipeline.swift        # + chosenWindow: one window, relevance forced, window reading written
├── Windows/
│   ├── VisibleWindows.swift          # split accepts the one recorded window when chosen
│   └── ReferenceClock.swift          # + windowOnly rule
└── Evaluation/
    ├── GoldenCase.swift              # meta.scope
    ├── PipelineCaseAnalyser.swift    # passes chosenWindow
    └── SyntheticWindowCaptures.swift # new: window-capture cases
App/
├── Adapters/
│   ├── WindowCaptureAdapter.swift    # new: WindowCapturing over ScreenCaptureKit and the window list
│   ├── ShortcutAdapter.swift         # three actions, per-action state, check against all others
│   └── FeedbackAdapter.swift         # + outline playing
├── Capture/CaptureOutlinePanel.swift # new: borderless click-through red outline
├── Windows/ShortcutSection.swift     # + "Capture window shortcut:" row
├── MenuContent.swift                 # + "Capture window"
└── AppEnvironment.swift              # wiring
docs/architecture/decisions/0028-window-capture-and-outline.md
```

**Structure Decision**: everything that can be tested without the screen (which window, outline rectangles, queue and busy rules, scope storage, the clock and relevance rules) lives in `MemorriCore`. The App target holds only the ScreenCaptureKit and AppKit adapters, kept thin.

## Complexity Tracking

No constitution violations to justify.
