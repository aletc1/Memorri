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
| `notGranted` | this process's own reading says granted while running | `restartRequired` (never seen in practice, see below) |
| `notGranted` | a freshly started copy of the app reports granted | `restartRequired` |
| `notGranted` | reported granted at a fresh launch | `granted` |
| `granted` | this process's own reading says not granted (revoked) | `notGranted` |
| `restartRequired` | this process's own reading, whatever it says | `restartRequired` (unchanged) |
| `restartRequired` | a freshly started copy reports not granted | `notGranted` |
| `restartRequired` | app relaunched and reported granted | `granted` |
| `granted` | a freshly started copy reports anything | `granted` (unchanged) |

Why a fresh copy: a running process keeps the permission answer it had at launch (research R5), so it can never see a grant made afterwards, and its own reading in the `restartRequired` state says nothing. A freshly started copy of the same app sees the current state at once. While a window that shows the status is open, the app starts one every 2 seconds (`--probe-permission`: print `granted` or `denied` and quit) and feeds the answer to `observeFreshProcess(granted:)`.

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
