# 21. Evidence cut-outs are saved with the item, and review state is stored on the item

- Status: Proposed
- Date: 2026-10-01
- Related: spec 006 (`specs/006-items-ui-evidence/`), ADR 0020, research R1 to R6

## Context and problem
The constitution asks that every item carry a cropped evidence image (II), that nothing below the confidence threshold syncs without approval (IV), and that raw data be kept under the user's control (V). Captures are deleted by retention, but the user wants the proof to stay as long as the item does (spec 006, clarification 4). The Inbox count must be cheap and live.

## Options considered
1. Cut on demand from the stored picture: no extra storage, but evidence disappears with the capture.
2. Save cut-outs per sighting, tied to the sighting: disappears with the capture too (sightings cascade).
3. Save cut-outs as files with an `evidence` row tied to the item, holding copies of the sighting's details; compute review state on every item recompute and store it on the item.

## Decision
Option 3. Cut-outs are written after reconciliation from the full-size picture, kept while the item exists, follow their sighting through merges, splits and undo, and are removed with the item, on reanalysis of their picture, and by "Delete everything". Their size is shown in Settings → Storage. Review reasons (low confidence below 0.75, guessed times, open possible duplicates, changes after approval) are stored on `items` with an approval snapshot; approval is an undoable operation, and "approved" (active and not needing review) is what Calendar sync will read.

## Consequences
- Easier: evidence survives retention; the Inbox and its count are one indexed query; spec 009 has a single rule to read.
- Harder: copies of sighting details in `evidence`; every operation that moves sightings must move evidence; screen content outlives its capture, which the storage figure and "Delete everything" make visible and controllable.
- Revisit: the 0.75 level after real use; whether retention should also apply to cut-outs of items not seen for a long time.
