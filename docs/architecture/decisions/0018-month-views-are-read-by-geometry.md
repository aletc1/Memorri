# 18. Month views are read from their lines and cells, not by the model

- Status: Accepted
- Date: 2026-10-01
- Related: spec 004, ADR 0014 (one pipeline, the model returns literal text), `specs/004-ocr-extraction-and-eval/research.md` "Changes made after a real three-display capture"

## Context and problem
ADR 0014 has the model list the findings of a picture and cite the lines that show them; code resolves the dates. A real month view (a Mac calendar on a 3440 x 1440 display, about 250 entries) showed the limits of that for this one screen kind:
- The extract call took 5 to 6 minutes and sometimes timed out.
- It returned 176 of about 250 entries and dropped whole days (a Friday was missing entirely).
- It copied a day number into every text field, wrote `deadline` for appointments, and gave an entry the time of its neighbour's cell.

In a month grid every entry is one line of text inside a day cell with its time at the right of the same row, and code already knows the cells (`DateResolver.monthCells`) and each line's position. The model had nothing left to decide.

## Options considered
1. Keep the model for month views and tune the prompt further, or send the grid in chunks.
2. Read the entries in code from the lines inside the grid and the cells; the model still classifies the picture.
3. Use a smaller model for the extract call.

## Decision
Option 2 for `calendar_month` pictures when `monthCells` finds a grid of at least 28 cells (`MonthEntries`). Every line in the grid that is not a day label, a time, an overflow marker ("y 2 más") or a stray glyph is an appointment: the title is the line's text without its bullet and its time, the time is the line that is only a time on the same row inside the same cell (or a time at either end of the line), and the date is the cell, as before. The result records `geometry-calendar_month-v1` where a prompt version goes. Everything else (week and day views, email, chat, documents) still goes to the model. Option 3 is a separate question about speed, to be decided from `memorri-eval` numbers.

Measured on the real month view: all entries of 12 spot-checked days matched the picture; the whole analysis took under a minute with the model's classify call at 3 s, against 5 to 6 minutes before.

## Consequences
- A month view no longer depends on the model's recall or its speed. The model only classifies it.
- Text from another window drawn over the grid (a dialog on top of the calendar) is read as entries; the model used to leave it out. Windows carry no usable stacking order today, so this is a known limit.
- Entries hidden behind "y N más" are not in the picture and are not found.
- Titles are exactly what the recogniser read, so a misread letter stays; the reading itself improved with enlarged tiles (`TiledTextRecogniser`, 2x), which found every entry of one kind (59 of 59) where unscaled tiles found half.
- Revisit for week and day views once the same measurements exist for them.
