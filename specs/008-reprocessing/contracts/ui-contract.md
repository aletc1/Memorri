# UI contract: Reprocess section of Settings > Analysis (spec 008)

Below the stored-captures section: `Reprocess` heading.
1. Start: model picker (installed vision models, default current), the prompt version as text (`extract v12/v13, windows v1`), `Start trial on N stored captures`, and `K captures were read with another model or prompt` (or `Everything was read with the current model and prompt`). Disabled with the reason when the server is down or the model is not installed.
2. Trials list (newest first): date, model, prompt, state, `read/skipped/failed of total`, Cancel or Resume, Delete, Open comparison.
3. Comparison (a sheet): totals row (new, changed, not found, unchanged, protected), `Compare with…` another trial, a list grouped by capture then item; each difference shows current value, proposed value, the cut-out, confidence, `You set this` / `Approved` / `Dismissed` for protected ones. Buttons: Apply selected, Apply all not protected; rows have checkboxes (protected ones disabled).
4. Audit: `History` list of apply operations (date, trial model, counts, undone) with Undo; the same operations appear in an item's History.
Accessibility: every control has a label; protected rows say why.
