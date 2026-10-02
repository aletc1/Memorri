# 2026-10-01: A month view of February was read as October

## Summary
A calendar left on February 2026 was analysed on 1 October 2026 and every entry got a date in October and November 2026. The month title and a day label that both said February were ignored, and the entries were still marked as read.

## Impact
Every item from the month views of one afternoon's captures (three pictures, 112 findings each) had its start date about nine months off. The items looked normal in the Items window: high confidence, dates "read", nothing in the Inbox. Found by the user looking at an item's evidence next to its date, not by any check.

## Timeline
- Spec 005/006 work: the Items window gains evidence cut-outs, so the picture sits beside the date for the first time.
- The user opens an item whose cut-out shows a calendar titled with February; the item says October.
- Reading the stored OCR lines of that capture showed the title line, a day label `1 feb` in the Sunday column of the third row, and a grid of 42 day numbers.

## Root cause
Two separate faults, hidden by one coincidence.

1. **The month title was never recognised.** `monthCells` looked for the shown month with `DateParser.parse`, which needs a day; a title such as `Febrero de 2026` or `October 2026` parses as nothing. The code then fell back to the month of the capture. Every test used a title in the same month as its capture date (October 2026), so the fallback gave the expected answer and the title code was never exercised.
2. **The day numbers cannot say which month it is.** 12 January 2026 and 12 October 2026 are both Mondays, both months have 31 days, and in both the next month starts on a Sunday. The two grids are identical; only words (the title, a label such as `1 feb`) name the month. The week-view headers had the same weakness, and when they had no usable title they silently took the nearest matching weekday and day to the capture date.
3. **No signal that the month was a guess.** A month taken from the capture date was recorded as `read` like everything else, so the review rules had nothing to react to.

A third thing made it worse to find: nothing compared a month view's dates with the picture's own words.

## Fix
- `DateResolver.monthTitle` recognises a line that only names a month (with or without a year, Spanish or English); month cells use the title over the grid, else a label that names a month (`1 feb`), else the capture month. Week headers use the same title, and try the neighbouring months for days that do not fit it (a week that spans two months).
- A date whose month nobody named is now `inferred` with the reason `month-assumed`, so the item shows "Guessed time" in the Inbox. `DateHeader.monthAssumed` carries it.
- The title, month labels and day numbers are looked for again in the calendar's own window (frontmost window holding the grid, minus windows in front of it), so another window's text cannot name the month.
- A day label without a month (`Wed 14`) takes it from a full-date header of the same view (`Wednesday, October 14, 2026`). Found by the synthetic eval: without it two day-view cases lost their "read" start flag.
- Tests where the shown month differs from the capture's month (Spanish and English titles, no title with a `1 feb` label, nothing naming the month, a side bar saying another month, week views, a week across two months) and a synthetic golden case, `calendar-month-other-month-es`: before the fix recall 0.00 (February entries came out in November), after it precision, recall and field accuracy 1.00.
- The whole synthetic set (28 cases, `qwen3-vl:8b-instruct`) compared with the last saved run: only the new case changed, and the two day-view cases that dipped are back to their old scores. Checked on the eight month views stored in the real database (counts only): the three February views now read 12 January to 22 February 2026; the October views are unchanged.

## Follow-ups
- [ ] (Implemented by spec 011 as a one-time background re-read on the first launch of the new build; not yet run on the real library.) The items already in the user's database keep the wrong dates until their pictures are read again from the stored text. Month views are read without the model, so this is cheap and exact; it rewrites sightings and items, so it needs the user's go-ahead (spec 008, reprocessing, or a one-off).
- [x] (Spec 011, ADR 0022.) Per-window analysis: split the screen into windows by stack order, classify and extract each calendar window on its own, take the date context from each window, and read the menu-bar clock as the reference date. It changes spec 004's design (one classification and one model call per picture today), so it needs its own spec.
- [x] (Spec 011: month conflict, `month-conflict`.) A check that compares a month view's dates with the words of the picture (title, labels, weekday names) and lowers confidence when they disagree.
