# 22. A capture is analysed window by window

- Status: Accepted
- Date: 2026-10-02
- Related: spec 011 (`specs/011-window-aware-analysis/`), ADR 0014, ADR 0018, ADR 0020, postmortem 2026-10-01 (month view read as the capture month)

## Context and problem
A capture shows several windows. Today one classification and one extraction read the whole picture, and the calendar is found afterwards from its text. Text of one window then decides things about another: the month of a calendar, the "today" of a mail, numbers that look like day labels. A calendar on February was read as October because of this.

## Options considered
1. One picture, smarter text filters (the stop-gap): cheap, but every new mix of windows needs a new filter.
2. One classification and one extraction per window: clean separation, but N+N model calls per capture.
3. One call that sorts all visible windows, then one extraction per relevant window (none for month grids), with the date context and reference clock taken per window.

## Decision
Option 3. Windows come from the stored stack and frames, minus what windows in front cover. The windows call replaces the classify call, so a one-window capture costs what it cost before. Each finding records its window; sightings and evidence copy the window's application and title. The old single-picture path stays for captures without a stack and when the windows call fails. After the update the library is re-read once in the background at low priority.

## Consequences
- Easier: dates and entries cannot leak between windows; two calendars on one screen work; the window shows in the item detail.
- Harder: more model calls on busy screens (bounded by relevant windows); two analysis paths to keep; window titles are stored (kept with the item, removed by "Delete everything", never logged).
- Evidence cut-outs show the identified window (or a 1400 x 800 area of a larger one). One model is enough for sorting windows: `qwen3-vl:8b-instruct` beat `minicpm-v4.5` on drawn multi-window screens (spec 011 research R11).
- Revisit: the cost per capture after a week of real use; whether remote desktops need their inner windows found from the picture.

## Results (2026-10-02)
Whole eval on `qwen3-vl:8b-instruct`, before (`875508a`) against after: the 28 older cases are unchanged (precision 0.843, recall 0.878, field accuracy 0.908), model calls 52 and 52, mean seconds per case 8.64 and 8.65 (+0.06%, limit +25%). The five new window cases score 1.00 precision and recall on dates and windows, with one windows call plus one extraction per relevant window that is not a month grid. `minicpm-v4.5` matches 9 of 16 findings on the new cases (the default 16 of 16), so one model stays. The table is in `specs/011-window-aware-analysis/research.md`.

