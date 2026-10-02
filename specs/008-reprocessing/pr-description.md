feat(reprocessing): trials, comparison and undoable apply (spec 008)

## What
- Settings > Analysis > Reprocess: pick an installed vision model and start a trial over all stored captures. It reads in the background behind new captures, shows progress, can be cancelled and resumed, and keeps its results apart from your items.
- Open a trial to compare it with the items: new items, changed fields (current and proposed values), items the trial did not find, and the evidence (cut-out and cited text). Anything you set, approved or dismissed is shown as protected and cannot be applied. Two trials can be compared with each other.
- Apply the differences you choose (or all that are not protected). It is one undoable operation, listed in History and in the item's history.
- The section says how many captures were read with another model or prompt.

## Why
Changing the model or a prompt used to mean reading everything blind. A trial cannot damage the library, so the effect can be seen first.

## Design
Trial tables (`trials`, `trial_images`, `trial_findings`, migration v10) and a `trial` job kind; the comparison is a dry run of the reconciler's plan over the proposals; apply replaces the capture's sighting of an item and stores the removed rows for Undo (ADR 0025).

Spec: `specs/008-reprocessing/`. ADR: 0025.

## Verification
- `swift test --package-path Packages/MemorriCore`: 1355 tests pass; new suites for the store, runner (the library is identical before and after), comparison (protections, totals, two trials), apply (idempotent, exact undo, locks untouched, later edit stops undo) and scale (1,000 captures compared in 1.3 s in a debug build).
- The app builds. The UI was not run: the author's own copy was running on the real library.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
