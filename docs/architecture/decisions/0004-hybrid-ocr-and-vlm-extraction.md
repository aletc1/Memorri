# 4. Hybrid OCR plus VLM extraction

- Status: Accepted
- Date: 2026-09-29

## Context and problem
A VLM alone gives unreliable coordinates for evidence crops and can misread small text.

## Decision
Apple Vision OCR runs on the full-resolution capture and yields lines with exact boxes. The VLM receives a downscaled image plus the numbered OCR lines, returns schema-constrained JSON, and cites OCR line IDs. Evidence crops are computed from the cited lines' boxes. Each display is captured and analysed separately, not stitched.

## Consequences
Two stages to maintain. Downscale size is configurable, and the eval harness sets its default.
