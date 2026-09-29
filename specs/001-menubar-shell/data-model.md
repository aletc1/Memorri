# Data Model: Menu-bar shell, hotkey and permissions

No database in this spec. These are in-memory types in `MemorriCore` plus a few persisted settings. Persistence for captures starts in spec 002.

## CaptureRequest (in memory, last 100 kept)

| Field | Type | Rules |
|---|---|---|
| `id` | UUID | Unique per request. |
| `timestamp` | Date | Time the request was accepted. |
| `trigger` | `menu` or `shortcut` | Which path produced it. |
| `permissionAtRequest` | `ScreenRecordingStatus` | Permission state when requested. |

Rules:
- A request within 300 ms of the previous accepted request is dropped (double press). Dropped requests are not recorded.
- When `permissionAtRequest` is not `granted`, the request is still recorded, but no feedback plays and the onboarding window opens instead (FR-010).
- The buffer keeps the newest 100 requests; older ones are discarded.

## ScreenRecordingStatus (state machine)

States: `granted`, `notGranted`, `restartRequired`.

| From | Event | To |
|---|---|---|
| (start) | launch, permission reported granted | `granted` |
| (start) | launch, permission not reported granted | `notGranted` |
| `granted` | a freshly started copy of the app reports not granted (revoked) | `notGranted` |
| `granted` | a freshly started copy reports granted | `granted` (unchanged) |
| `notGranted` | a freshly started copy reports granted | `restartRequired` |
| `notGranted` | a freshly started copy reports not granted | `notGranted` (unchanged) |
| `restartRequired` | a freshly started copy reports not granted | `notGranted` |
| `restartRequired` | a freshly started copy reports granted | `restartRequired` (unchanged) |
| `restartRequired` | app relaunched, launch reading granted | `granted` |

Why only fresh-copy reports after launch: a running process keeps the permission answer it had at launch, so it can see neither a grant nor a revocation made afterwards (research R5; confirmed by logs on 2026-09-29, including a revocation that the running app never noticed). A freshly started copy of the same app sees the current state at once. Every 2 seconds, and whenever the app becomes active, the app starts one (`--probe-permission`: print `granted` or `denied` and quit) and feeds the answer to `observeFreshProcess(granted:)`. A probe costs about 20 ms and about 1 ms of CPU. Re-granting after a revocation also gives `restartRequired`, because the process cannot tell whether its own view is still valid. The capture path reads the tracked status, never the process's own reading.

## ShortcutSetting (persisted by the KeyboardShortcuts package)

| Field | Type | Rules |
|---|---|---|
| `combo` | `KeyCombo?` (key plus modifiers) or none | Default Control+Option+Command+M. `none` means no shortcut is registered. |

`KeyCombo` (in the core): `keyCode: Int`, `modifiers: Set<Modifier>` with `Modifier` in control, option, command, shift.

Validation (`ShortcutValidator`), applied in this order, first failure wins:
1. `noModifier`: the modifier set is empty.
2. `usedByMemorriAction(actionName)`: another Memorri action uses the same combo.
3. `reservedBySystem`: reported by the system-shortcut checker.

A rejected combo leaves the stored value unchanged. Reset to default restores Control+Option+Command+M and is subject to the same checks (if the default is now taken by the system, the reset reports it and keeps the current value).

## CaptureFeedbackSettings (UserDefaults)

| Key | Type | Default |
|---|---|---|
| `memorri.feedback.flashIcon` | Bool | `true` |
| `memorri.feedback.playSound` | Bool | `true` |

## FirstLaunchState (UserDefaults)

| Key | Type | Default |
|---|---|---|
| `memorri.onboarding.completed` | Bool | `false` |

Set to `true` at the first launch, whatever the permission state. At that launch the onboarding window opens on its own only if the permission is not `granted`; at every later launch it does not open on its own (clarification 4). A capture requested without the permission opens it regardless (FR-010).
