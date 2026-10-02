# 23. Search index in the library database

- Status: Accepted
- Date: 2026-10-02
- Related: spec 007 (`specs/007-search/`), ADR 0003 (SQLite and GRDB), ADR 0020, ADR 0022

## Context and problem
Memorri keeps items, aliases and the recognised text of every capture. The user needs to find any of it by a few words, with filters, from anywhere, and the results must always match the library as it is.

## Options considered
1. FTS5 tables in the library database, kept by triggers (items) and by the transaction that stores the text (captures).
2. A separate index file or Core Spotlight.
3. LIKE scans over the tables.

## Decision
Option 1. Two derived FTS5 tables (`search_items`, `search_captures`) with case and accent folding. Item documents are replaced by triggers on `items` and `item_aliases`; a capture document is written with the capture's lines and removed by a trigger when the capture is deleted. A version in `search_meta` makes a launch rebuild the index in the background when it is missing or outdated. Capture matching lines and window names are found after ranking, for the page shown.

## Consequences
- Easier: freshness is part of every write, including future ones; one file to back up or delete; "Delete everything" cannot leave text behind.
- Harder: triggers must be kept in step with the searchable columns of `items`; a capture document is rewritten whole when its text is read again; the index adds disk (about the size of the text).
- Revisit: result quality on real libraries (typo tolerance, stemming); the size of `search_captures` after months of use.

## Results (2026-10-02)
Measured on a library of 5,000 items (with one alias each) and 200 captures of 1,000 lines (200,000 lines), best of three, `SearchScaleTests`:

| Query | Release | Debug |
|---|---|---|
| two words, one a prefix, among items | 0.9 ms | 1.4 ms |
| two common words, a page of captures with their lines | 24 ms | 28 ms |
| one rare word, a page of captures | 18 ms | 21 ms |
| first results with a kind filter | 1.0 ms | 1.6 ms |

The limits (200 ms, 300 ms) hold with a wide margin. Writing a capture's document for 1,000 lines costs under 50 ms (an analysis takes seconds). A full rebuild equals the index the triggers kept (rows of both tables compared). The first version of capture results read every line of each of the 20 captures and took 0.45 s in a debug build; filtering the lines in SQL (the word as a substring, plus every line with an accent) and a cheap ASCII test before folding brought it to the figures above.

