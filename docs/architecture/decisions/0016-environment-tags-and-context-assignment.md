# 16. Environment tags and context assignment

- Status: Accepted
- Date: 2026-09-30
- Related: spec 004 (FR-014 to FR-016, FR-026 to FR-030), Constitution II and IV, spec 005 (reconciliation)

## Context and problem
The same meeting may appear in several captures and two similar items may differ. Spec 005 needs cheap evidence for "same place or not" (which application, which platform, which remote session, which account, 12 or 24 hour time). Time zones also depend on which customer a capture came from. Window titles and account names can be sensitive.

## Options considered
1. No tags; reconciliation compares text only.
2. Model-only tags in one call.
3. Tags from three sources with provenance: the capture (display size, window titles and owning applications), the text lines (language, clock style, date order, accounts and domains, time zone labels) and the model's visual judgement in the classification call (application, platform look, remote session, theme, calendar name). Contexts are matched by transparent hint scores; a user choice is final.

## Decision
Option 3. Each tag has a key, value, confidence and source; unknown is not stored; visual tags carry the classification confidence and count as low below 0.6. Findings keep a copy of their picture's tags. Window titles are recorded at capture (up to 20 per display) and, like tags, stored only locally and deleted with the capture. Context matching scores window title and application hints 3, domain 2.5 and keyword 1, needs 2 points and a lead of 1, records ties and the runner-up, and never replaces a user choice. Differing tags never decide "different items" alone; spec 005 owns the comparison.

## Consequences
- Privacy: titles, account names and domains are sensitive data stored for the life of the capture (7 days by default) and never logged or sent.
- The key list can grow without a migration (no CHECK on `key`), validated in code.
- Hint weights and thresholds are constants that the eval set can tune later.
