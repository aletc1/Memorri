# 28. A window capture is the screen inside one window's outline, analysed as a chosen window

- Status: Proposed
- Date: 2026-10-02
- Related: spec 013 (`specs/013-active-window-capture/`), ADR 0008, ADR 0009, ADR 0016, ADR 0022

## Context and problem
Every capture takes every display. The user wants a second shortcut that records only the active window, shows what was recorded with a red border, and has Memorri read that window alone. The full-screen capture must not change. Three choices have no obvious answer: how to know which window is active, what pixels the picture holds, and how the analysis learns that the user chose the window.

## Options considered
1. Active window by Accessibility (`AXFocusedWindow`): exact, but a second permission and onboarding for one corner case.
2. Active window as the front-most ordinary window of the frontmost application, from the window list Memorri already reads: no new permission; wrong only for a focused non-activating panel.
3. Pixels by window id (the window's own content, including what is covered): cleaner picture, but it can show what the user could not see, and the red border would not match what was on screen.
4. Pixels by rectangle (the screen inside the outline): matches the border and what the user saw; a window over the front window is included.
5. Analysis: a new storage scope read by the existing per-window path, with the relevance answer forced, against a separate analysis path for window captures.

## Decision
Options 2, 4 and the first form of 5. The window is found from the frontmost application and the system's front-to-back window list. The picture is the screen inside the window's outline, from a display filter with a source rectangle (one display) or a rectangle across displays (spanning). The event is stored with `scope = window`, one picture and one window that fills it. The analysis uses the per-window path with that one window, keeps the windows call to decide the kind of view, and sets relevance to true. The reference clock looks only inside the window and does not flag a missing clock. A click-through red outline window, created after the picture is stored, shows the recorded area for about a second.

## Consequences
- Easier: no new permission; one analysis path; window names reach sightings and evidence through the normal window reading; the full-screen code paths are not edited.
- Harder: text of a window drawn over the chosen one can be read; a focused non-activating panel can be missed; the spanning case cannot exclude Memorri's own windows; the outline needs a manual check over full-screen Spaces.
- Revisit: Accessibility if real use shows wrong windows; the spanning-display fallback after spike S1; the outline level after spike S2.
