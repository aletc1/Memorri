# 8. Configurable global hotkey

- Status: Accepted
- Date: 2026-09-29

## Context and problem
The user wants a shortcut that no app or the OS uses. Cmd+Shift+P is used by print dialogs and command palettes, and Cmd+Shift+3/4/5 by macOS screenshots. Remote-desktop clients may also capture keystrokes.

## Decision
Use the KeyboardShortcuts package (sindresorhus) so the shortcut is user-configurable. Default is Control+Option+Command+M. The menu-bar icon menu always offers Capture as a fallback. Spec 001 requires the hotkey to work while a remote-desktop client is focused.

## Consequences
Adds one dependency. If a remote-desktop client swallows the key, the user picks another combination.
