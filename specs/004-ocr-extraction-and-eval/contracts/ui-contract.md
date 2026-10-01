# UI Contract: spec 004

What the user sees. Changes to the contracts of specs 001 to 003 are marked.

## Menu (no text change)

The analysis line and Pause/Resume from spec 003 stay as they are. Picture analysis jobs count like any other job: `Analysing 1 of 4…`, `Analysis: 3 waiting`, `Analysis: idle, 1 failed`. No notifications.

## Settings → Analysis (new row between Ollama and Storage)

Top to bottom, in a scrolling view:

1. **Automatic analysis**: a switch `Analyse new captures automatically` (default on) with the note `Turn it off to capture without analysing. Pause analysis in the menu stops work without changing this.`
2. **Stored captures**: a button **Analyse stored captures** with the note `<n> captures have not been analysed.` (button disabled when 0); pressing it adds them to the queue, oldest first.
3. **Recent captures**: up to 20 rows, newest first, each with: time, number of displays, a state (`Waiting`, `Analysing…`, `Analysed`, `Failed: <reason>`, `Not analysed`), the screen kind (`Calendar week`, `Calendar month`, `Calendar day`, `Email`, `Chat`, `Document`, `Other`), the context (`Customer A` or `Unassigned`, shown in the picker, with `(chosen by you)` beside it when it is the user's), the finding count, the tags as small labels (application, platform look, remote client, clock style, language, theme), a context picker (`Unassigned` plus every context), **Reanalyse**, and a disclosure `Findings` listing each finding as `<kind> · <title> · <start or due in the picture's zone>` with `(inferred end: block height)` or `(inferred end: default 1 h)` or `(date unresolved: "<text>")` when it applies. Per display picture when a capture has several.
4. **Contexts**: a list with **Add context**; each row has a name field, a time zone picker (`Mac's time zone` first), a list of hints (kind picker: Window title, Application, Domain, Keyword; value field), add and remove hint buttons and **Delete**. Deleting asks for no confirmation and leaves pictures unassigned. A name already in use (ignoring case) shows `That name is already used.`; a hint shorter than 2 characters shows `Enter at least 2 characters.` and is not saved.

Texts on screen come from the user's own captures; this view is in the user's own app window, like the rest of Settings.

## Debug switch (Debug builds only)

`open -n Memorri.app --args --ingest-picture /path/to/picture.png` stores the picture as a capture (one display, full and analysis copies, no window list unless `--ingest-windows <json>` is also given) and queues it, so scenarios run without capturing the screen. Not compiled into Release builds.

## Log contract (for the quickstart)

Subsystem `com.aletc1.memorri`. Category `extraction`: `read image=<id> lines=<n> ms=<n>`, `classify image=<id> kind=<kind> confidence=<x> ms=<n>`, `extract image=<id> kind=<kind> findings=<n> discarded=<n> ms=<n>`, `resolve image=<id> unresolved=<n> inferred=<n>`, `context image=<id> source=<auto|user|none> name=<name|->`, `analysis stored image=<id>`. Category `analysis` keeps the lines from spec 003 and adds `enqueued analyse=<n> reason=<capture|backlog|reanalyse>`. Nothing read from the screen (text, titles, tag values) is logged.
