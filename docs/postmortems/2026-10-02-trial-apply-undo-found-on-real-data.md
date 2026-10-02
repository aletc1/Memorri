# 2026-10-02: Trial apply and undo, two bugs found by running it on the real library

## Summary
Running a reprocessing trial's apply and undo on the developer's real library (spec 008) showed two bugs that the unit tests had not: an apply removed more of a capture's sightings than the chosen difference stood for, and the first undo restored only one of the two sightings it had removed.

## Impact
One real item (a calendar entry read twice in each of three captures) ended with its title changed to the correct spelling and one of its sightings missing, with the undo recorded as done. Sightings went from 338 to 337. The library was repaired from the stored before-image (operation log edit by the developer, then Undo again); the final state matched the start (338 sightings, original title). No other item was touched.

## Timeline
- Trial of 9 captures over the stored library: 335 unchanged, 3 changed. The three rows showed the same title twice.
- A look at lengths and character positions only (no content) showed the titles differed in one letter (`I` against `l`) that the app's font draws alike. The comparison now names the letter.
- Apply of one difference: the item's title changed as intended; sightings fell to 337.
- Undo: recorded as done; the second removed sighting was not restored; the item stayed changed.
- Fixes with tests, a backup of the database, an operation-log edit to reopen the undo, Undo again: back to 338 and the original title. A second full run (apply of three, undo) kept 338 throughout.

## Root cause
- **Over-removal.** The apply removed every sighting a capture had of the item before attaching the chosen proposal. Each capture here showed the event twice, so the unselected reading was lost too. Wrong assumption: one sighting per capture and item. A re-read does replace all of them, but a chosen difference stands for one reading.
- **Undo guard.** To avoid putting an old sighting back next to a newer one after the capture was read again, the undo skipped a sighting when the capture already had one for that item. With two removed readings, the first one restored made the second look like a re-read. Wrong assumption: the capture never holds a sighting of the item that the undo itself put back. After the first fix it also fired whenever the capture kept an untouched sibling.
- The tests built items with one sighting per capture, and the snapshot test for undo could not see a case with two.

## Fix
- The apply replaces only the old sighting a proposal stands for (same title exactly, then same title once normalised, then one no other proposal accounts for) and stores it for Undo. It also stores the ids of the sightings that stayed.
- The undo guard compares with what the capture showed at apply time (removed plus kept ids), so only sightings made since count as a later re-read.
- Tests: a capture with two readings where one is applied (the other stays, undo restores exactly), an apply that replaces both, and the later re-read case.
- The comparison names the letter that differs when two texts look alike.

## Follow-ups
- [ ] Opening the comparison and re-running it after an apply takes about fifteen seconds on the real library in a debug build, because the plan uses the live meaning judge. Consider a plan without the judge for the comparison view, or caching it per trial.
- [ ] The Reprocess sheet does not show it is working while it recomputes; add a progress indicator.
- [ ] Run the UI once more on a release build.
