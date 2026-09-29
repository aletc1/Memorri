# UI Contract: Menu-bar shell

What the user sees and what tests and the quickstart check. Wording is final unless the spec changes.

## Menu-bar item

- Icon: template image `MenuBarIcon`; flash variant `MenuBarIconFlash` shown for about 300 ms.
- No Dock icon (`LSUIElement`), no main window, no app menu.

## Menu (top to bottom)

| Item | Action | Notes |
|---|---|---|
| Capture now | request a capture (trigger `menu`) | Shows the current shortcut to the right when one is set. |
| Inbox | open the Inbox placeholder window | |
| Search | open the Search placeholder window | |
| (separator) | | |
| Grant Screen Recording access… | open the onboarding window | Present only while the status is not `granted`. Shows "Restart to finish setup…" when `restartRequired`. |
| Settings… | open Settings | Shortcut Command+, while the menu is open. |
| (separator) | | |
| Quit Memorri | quit | Shortcut Command+Q while the menu is open. |

## Windows (one instance each; opening again fronts the existing one)

| Id | Title | Content |
|---|---|---|
| `settings` | Memorri Settings | Sidebar and detail. |
| `onboarding` | Screen Recording Access | Status, reason, buttons. |
| `inbox` | Inbox | "The Inbox is not built yet. It arrives in a later version." |
| `search` | Search | "Search is not built yet. It arrives in a later version." |

All windows open on the display that holds the pointer and are brought to the front on open.

## Settings sections (sidebar order)

1. **General** (selected by default): shortcut recorder, "Reset to default" button, toggles "Flash the menu-bar icon" and "Play a sound" for capture feedback.
2. **Permissions**: Screen Recording status row and the same actions as onboarding.
3. **Ollama**, **Storage**, **Calendar sync**: placeholder text "Coming in a later version: <what will be here>." Each names its future spec (003, 002, 009).

## Onboarding window

- Explains in one short paragraph why Screen Recording is needed (to see the screens you choose to capture; nothing leaves this Mac).
- Status badge: Granted, Not granted, or Restart required.
- Buttons: **Open System Settings** (first requests access so the system prompt appears and the app is listed, then opens the Screen Recording pane), **Check again**, and, when `restartRequired`, **Relaunch Memorri**.
- The status updates on its own within 2 seconds of the change; no button press is needed (User Story 3, scenario 3).

## Shortcut rejection messages

| Rule | Message |
|---|---|
| noModifier | "A shortcut needs at least one modifier key (Control, Option, Command or Shift)." |
| usedByMemorriAction | "This shortcut is already used by <action> in Memorri." |
| reservedBySystem | "macOS already uses this shortcut." |

The previous shortcut stays selected after any rejection.

## Capture feedback

- Icon flash then return to normal, about 300 ms. Sound: a short system sound. Each can be turned off.
- With no permission: no flash and no sound; the onboarding window opens.

## Persisted keys

`memorri.feedback.flashIcon`, `memorri.feedback.playSound`, `memorri.onboarding.completed` in `UserDefaults`; the shortcut is stored by the KeyboardShortcuts package under its own key for the name `capture`.

## Cross-process signal

Distributed notification `com.aletc1.memorri.openSettings`: posted by a second launch, handled by the running instance by opening Settings.

## Log contract (used by manual tests)

Subsystem `com.aletc1.memorri`, category `capture`. One line per accepted request: `capture requested trigger=<menu|shortcut> permission=<granted|notGranted|restartRequired>`. View with `log stream --predicate 'subsystem == "com.aletc1.memorri"'`.
