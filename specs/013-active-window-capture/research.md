# Research: Capture only the active window

Facts about the code come from reading the repository on 2026-10-02. Items marked **Verify** are checked by a spike in the first tasks, before the code that depends on them.

## R1. Where the choice of window comes from

**Decision**: `NSWorkspace.shared.frontmostApplication` gives the process; the system's front-to-back list of on-screen windows (already read for the stack in the display capturer, `CGWindowListCopyWindowInfo`) gives the order; `SCShareableContent.windows` gives frames, titles and application names. Pure logic (`ActiveWindowPicker`) takes that list and the two process ids (frontmost, Memorri's own) and returns the window or the reason there is none.

**Rationale**: Nothing new is asked of the user; Screen Recording already covers listing windows. The picker is testable without a screen.

**Alternatives**: the Accessibility API (R2); `NSEvent` global monitors (no use, they report keys not windows).

## R2. Keyboard focus without Accessibility

**Decision**: The "window with keyboard focus" is taken as the front-most layer-0 on-screen window of the frontmost application. macOS orders the key window of the active application in front of its other ordinary windows, so this matches the focused window in normal use. Floating panels and other windows above layer 0 are skipped. A non-activating panel that has focus is the one case it can miss.

**Rationale**: Reading the focused window (`AXFocusedWindow`) needs the Accessibility permission, a second permission with its own onboarding for one corner case. The red border shows at once if the wrong window was taken, and the user presses again.

**Alternatives**: ask for Accessibility and use `AXFocusedWindow` (exact, costs a permission and onboarding step; revisit if real use shows misses). Recorded as an assumption in the spec.

## R3. Taking the pixels inside the outline

**Decision**: When the window lies on one display, use a display filter that excludes Memorri's own windows, with a source rectangle equal to the window's frame in that display's coordinates, at the display's native scale. When it spans displays, take the rectangle across displays with `SCScreenshotManager.captureImage(in:)` (macOS 15.2+, available at the app's minimum). Both give the screen as drawn, so a window or panel over the front window is included and the covered content is not (Q1 B). A frame partly off the screen is clipped to the screens first.

**Rationale**: The rectangle APIs return what is on the screen inside the outline, which is exactly Q1 B; capturing the window by its own id would give the window's full content, which is Q1 A and was not chosen.

**Verify (S1)**: the pixel size and scale that `captureImage(in:)` returns when the displays have different scales, and that a source rectangle on a Retina display returns native pixels. If the spanning case cannot be made right, the plan falls back to the part of the window on the display that holds most of it, with the border drawn on that part only, and the spec edge case is amended.

**Known cost**: the rectangle-across-displays call cannot exclude Memorri's own windows. Memorri's search panel could appear in that rare picture. Accepted; the single-display path, which is nearly every capture, excludes them.

## R4. How the window capture is stored

**Decision**: one `capture_events` row with the new `scope = 'window'` and the usual `trigger` (`menu` or `shortcut`), one `capture_images` row (display id and name of the display with the largest share, its scale, picture size), and one `capture_windows` row for the window itself with a frame covering the whole picture, stack 0, application name and title. A nullable `desktop_frame_json` on the image keeps the window's frame on the desktop (FR-009). The `trigger` check constraint is not touched: scope is a separate column, so no table rebuild is needed (SQLite allows adding a column with a default and a check).

**Rationale**: every later step reads images and windows already. Nothing downstream needs to know the picture is a window except the analysis (R5).

**Alternatives**: a new `trigger` value (needs a rebuild of `capture_events`); a separate table (every reader would need a second path).

## R5. Analysing one chosen window

**Decision**: today a picture with fewer than two recorded windows is read whole (`analyseWhole`, classify then extract) with no window reading, so no window name reaches sightings or evidence. For `scope = window` the analysis takes the per-window path with one window: `split` accepts the single recorded window, the windows call runs as usual to decide the kind of view, its `relevant` answer is replaced with true (FR-015), the window is extracted on its own, and the window reading is written, so the sighting and evidence carry the application and title (FR-009, FR-018). If the windows call fails or answers badly, the existing fallback reads the picture whole, which is the window itself. The prompt and schema are unchanged, so Principle VI needs only new eval cases, not a prompt comparison.

**Rationale**: the cheapest change that keeps one reading path and gives the names. The cost is one windows call plus one extraction, as for a full-screen capture of a few windows.

**Alternatives**: skip the windows call and use the classify call (a different prompt path for one case); keep `analyseWhole` and pass the names separately (a second route for names to reach the sighting).

## R6. The reference clock for a window picture

**Decision**: add a `windowOnly` rule to `ReferenceClock.find`: look for a clock only in the window's own top and bottom strip (as spec 011 does for remote windows), never in a screen strip; when none is found use the capture time and do not flag the dates for that reason (FR-016); a clock more than a day from the capture time still flags (spec 011). The strip search runs under the same condition as in spec 011 (the window judged remote).

**Rationale**: spec 011 flags dates when no clock is found because with windows known a menu-bar clock should have been there. A window picture has no menu bar, so the flag would mark every relative date as a guess.

## R7. Queue and double presses

**Decision**: new captures already enqueue at priority 0 and the library re-read at 1, so a window capture needs no queue change (FR-018a). The pipeline actor's `isRunning` guard and the service's 300 ms debounce are shared by both entry points, so a double press counts once and a request during a capture is ignored (FR-020). The debounce is moved to cover both scopes by keeping one `lastAccepted` in the service.

## R8. The red outline

**Decision**: one borderless, non-activating `NSPanel` per display the outline touches, covering that display, with `ignoresMouseEvents = true`, `canBecomeKey/Main = false`, clear background, level above the main menu and full-screen windows, collection behaviour for all Spaces and full-screen auxiliary, `sharingType = .none`. It draws a red rounded-corner-free stroke of 4 points inside the recorded rectangle, shows after the capture is stored and fades after about a second. The rectangle for each display comes from a pure function in the core package (desktop frame in, display-local rectangles out, y flipped from the capture coordinate system to AppKit's).

**Rationale**: the window appears only after the picture exists, so it cannot be in it; Memorri's own windows are excluded from display captures anyway; `sharingType = .none` is a second guard. Clicks pass through.

**Verify (S2)**: that a panel with this configuration shows over a full-screen application in a different Space, from a menu-bar-only (`LSUIElement`) app. If not, raise the level or use the `.stationary` and `.ignoresCycle` behaviours; if it still fails, document the limit.

## R9. Migration number

**Decision**: the migration is `v13`, registered after `v12`. Specs 009 and 010 are merged and use `v11` and `v12`. Migrations are applied in registration order by name, so the name must be unique and registered last.

## R10. The shortcut conflicts

**Decision**: `ShortcutAdapter` becomes three actions (capture, window, search) with per-action state instead of two ternaries, and each check compares against every other action through the existing `ShortcutValidator` (which already takes a dictionary of other actions). If a user's saved capture or search shortcut already equals the new default Control+Option+Command+W, the window shortcut starts unassigned and Settings says so, instead of overriding the user's choice.

## R11. What is measured

Existing eval cases must score the same (precision, recall and field accuracy unchanged, model calls unchanged). New cases (R5, R6): a mail alone, a month calendar on a month other than the capture's with no menu bar, a remote window with its own clock, a calendar with a panel drawn over part of it, a terminal window (read, no items). Per-case scores are reported.

## Baseline (before the change)

`memorri-eval run` on `main` (commit `2c2cd93`, before any 013 code), default model, 2026-10-02: 33 cases (synthetic 33, local 0), mean 11.8 s per case, 65 model calls; findings precision 0.88, recall 0.91, field accuracy 0.93. The full report is kept outside the repository. Task T040 compares the run after the change with these figures.
