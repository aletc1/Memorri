# 10. Only raw captures expire; items keep their own evidence

- Status: Accepted
- Date: 2026-09-30
- Related: spec 002 (FR-023), constitution principles II and V

## Context and problem
Raw captures are large and sensitive, so they expire (retention policy) and can be deleted by the user. The appointments, tasks and reminders found in them are the point of the product and must outlive them. The constitution requires that every item carries evidence, a cropped piece of the screenshot.

## Options considered
1. Items reference the capture for their evidence: simple, but expiring or deleting a capture breaks the evidence of every item found in it.
2. Keep the capture records and pictures as long as any item refers to them: safe for evidence, but the largest and most sensitive data then never expires.
3. Each item stores its own evidence (the cropped picture and the time it was seen) and never depends on the capture: captures can expire freely.

## Decision
Option 3. Retention and every cleanup apply to captures only (their records and pictures, deleted together). They never delete, change or make unreadable anything derived from captures. Specs that create items (004 and later) must copy the evidence crop and the capture time onto the item and must not keep a required reference to a capture record or picture.

## Consequences
- Reprocessing (spec 008) can only use captures that still exist; after expiry, an item keeps its crop but cannot be re-read from the full picture.
- Evidence crops are small, so keeping them forever is cheap; they are still sensitive and the delete-all option for items, when added, must remove them.
- The spec 004 schema has no foreign key from items to `capture_events`; if a reference is kept for convenience it is nullable and set to null when the capture is deleted.
