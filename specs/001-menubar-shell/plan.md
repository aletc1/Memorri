# Implementation Plan: Menu-bar shell, hotkey and permissions

**Branch**: `001-menubar-shell` | **Date**: 2026-09-29 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-menubar-shell/spec.md`

## Summary

Create the Memorri project from nothing: an XcodeGen-generated macOS 26+ menu-bar-only app plus a local Swift package `MemorriCore` that holds all testable logic. The app shows a menu-bar icon and menu, a configurable global hotkey (default Control+Option+Command+M), placeholder Inbox and Search windows, a Settings window skeleton, and Screen Recording permission onboarding. "Capture" only records a request and gives feedback (icon flash plus sound); the real screenshot is spec 002. Local builds are signed with the stable "Memorri Local" identity so the permission survives rebuilds.

Approach: SwiftUI `MenuBarExtra` for the menu, an AppKit window coordinator for all windows (reliable to open from a hotkey or a second launch), the `KeyboardShortcuts` package for the shortcut and its recorder, and a pure-Swift core for the capture-request service, shortcut validation, permission state machine and settings. See [research.md](research.md) for the decisions.

## Technical Context

**Language/Version**: Swift 6 (Xcode toolchain on this Mac: Swift 6.4), strict concurrency on

**Primary Dependencies**: SwiftUI, AppKit, ScreenCaptureKit/CoreGraphics (permission check only), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (SwiftPM, pinned to exactly 2.4.0 in `project.yml`; the generated project and its `Package.resolved` are not committed). No other third-party dependencies. The GRDB dependency arrives in spec 002.

**Storage**: `UserDefaults` for settings (shortcut is stored by KeyboardShortcuts). No database in this spec.

**Testing**: Swift Testing (`import Testing`) in `Packages/MemorriCore/Tests`, run with `swift test`. UI and hotkey-in-remote-desktop behaviour are verified manually with [quickstart.md](quickstart.md).

**Target Platform**: macOS 26+, Apple silicon Mac

**Project Type**: desktop-app (menu-bar agent) plus a local Swift package

**Performance Goals**: icon visible within 2 s of launch (SC-001); capture request handled and acknowledged within 100 ms of key press.

**Constraints**: no network access of any kind (FR-017); unsandboxed, no notarization (ADR 0007); no Dock icon; single instance; the app must not need Accessibility or Input Monitoring permission for the hotkey.

**Scale/Scope**: one user, one Mac; about 4 windows (Settings, Onboarding, Inbox placeholder, Search placeholder) and one menu.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Local-first and private | Pass | No network code. FR-017 is checked by a source scan (no `URLSession`, `NWConnection` or `import Network`) plus a one-time runtime check that the running app holds no connections. The app is unsandboxed, so the absence of an entitlement proves nothing on its own. |
| II. Every item carries evidence | N/A | No items yet. |
| III. Idempotent, no duplicates | N/A | One relevant rule: a single key press produces exactly one capture request (SC-002), covered by a debounce test. |
| IV. The user wins | Pass | The user's shortcut choice persists and is never overwritten; the previous shortcut is kept when a new one is rejected. |
| V. Raw data kept under user control | N/A | No data stored yet. |
| VI. Test-first core, measured prompts | Pass | All logic lives in `MemorriCore` and is written test-first (tasks order tests before code). No prompts yet. |
| VII. Incremental, always runnable | Pass | Ends with a runnable menu-bar app; nothing from later specs is started. |
| VIII. Decisions recorded | Pass | Relies on ADRs 0002, 0007, 0008. New choices (AppKit window coordinator, single-instance mechanism) are recorded in `research.md`; they do not change an accepted ADR. |

Technical constraints check: Swift 6, macOS 26+, XcodeGen, self-signed identity, unsandboxed. All consistent. **Post-design re-check: pass, no violations.**

## Project Structure

### Documentation (this feature)

```text
specs/001-menubar-shell/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── ui-contract.md           # menu, windows, settings sections, user-visible strings
│   └── core-interfaces.md       # MemorriCore protocols and the cross-process signal
├── checklists/requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
project.yml                      # XcodeGen definition (generated .xcodeproj is gitignored)
App/
├── MemorriApp.swift             # @main, MenuBarExtra, app delegate adaptor
├── AppDelegate.swift            # single-instance check, lifecycle, distributed-notification listener
├── AppEnvironment.swift         # wires the core services to the system adapters
├── MenuContent.swift            # the menu
├── Windows/
│   ├── WindowCoordinator.swift  # opens/fronts the single instance of each window (AppKit)
│   ├── SettingsView.swift       # sidebar: General, Permissions, Ollama*, Storage*, Calendar sync*
│   ├── ShortcutSection.swift    # recorder, clear and reset, rejection messages (used in General)
│   ├── OnboardingView.swift     # Screen Recording status and grant flow
│   └── PlaceholderView.swift    # Inbox and Search placeholders
├── Adapters/
│   ├── ScreenRecordingAdapter.swift   # CGPreflight/CGRequest, System Settings deep link
│   ├── ShortcutAdapter.swift          # KeyboardShortcuts registration and recorder bridge
│   └── FeedbackAdapter.swift          # icon flash, NSSound
├── Resources/
│   └── Assets.xcassets              # menu-bar icon (template image), flash variant
└── Info.plist                       # generated by XcodeGen: LSUIElement, usage descriptions
scripts/
├── create-signing-certificate.sh    # exists (ADR 0007)
└── check-signing-identity.sh        # pre-build phase: fails with a clear message if the identity is missing
Packages/MemorriCore/
├── Package.swift                    # tools 6.2+, macOS 26
├── Sources/MemorriCore/
│   ├── Capture/                     # CaptureRequest, CaptureRequestService, CaptureTrigger, Clock, FeedbackPlaying
│   ├── Lifecycle/                   # SingleInstanceArbiter
│   ├── Permissions/                 # ScreenRecordingStatus, PermissionMonitor, OnboardingPolicy
│   ├── Shortcuts/                   # KeyCombo, ShortcutValidator
│   └── Settings/                    # CaptureFeedbackSettings, SettingsStore protocol, UserDefaultsSettingsStore
└── Tests/MemorriCoreTests/          # unit tests for every folder above
```

**Structure Decision**: an app target `Memorri` (folder `App/`) that only wires and presents, and one local package `MemorriCore` (folder `Packages/MemorriCore/`) that holds every rule that can be tested without a UI. System calls (permission check, key registration, sound, icon flash) sit behind small protocols in the core with adapters in the app, so tests use fakes. This matches the layout already declared in `CLAUDE.md` and ADR 0002. `Tools/memorri-eval` is not created here (spec 004).

## Complexity Tracking

No constitution violations. Nothing to justify.
