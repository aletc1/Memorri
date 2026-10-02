# 23. Search index in the library database

- Status: Proposed
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
