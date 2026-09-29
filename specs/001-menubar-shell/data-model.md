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
| `notGranted` | reported granted while running | `restartRequired` |
| `notGranted` | reported granted at a fresh launch | `granted` |
| `granted` | reported not granted while running (revoked) | `notGranted` |
| `restartRequired` | app relaunched and reported granted | `granted` |
| `restartRequired` | reported not granted | `notGranted` |

If research item R5 shows no relaunch is needed on macOS 26, the `notGranted` → `restartRequired` row becomes `notGranted` → `granted` and the `restartRequired` state stays unused.

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

Set to `true` when the onboarding window is first shown at launch, so the automatic window appears only once (clarification 4). It is independent of the permission state.
