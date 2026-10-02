# 26. Sync as a pure planner over a scoped event store

- Status: Accepted
- Date: 2026-10-02
- Related: spec 009 (`specs/009-eventkit-sync/`), ADR 0006 (EventKit sync targets), ADR 0020, ADR 0021

## Context and problem
Spec 009 writes items into the user's Calendar and Reminders. The user's Personal and Work calendars are synced with mail and other tools and must never be touched; Memorri works in a calendar and a list the user made for it. Writes into someone's real calendar must be exact (no duplicates, no stray deletes), previewable, and testable without prompting for access.

## Options considered
1. Call EventKit directly from the sync code, one item at a time.
2. A pure planner (`SyncPlanner`) that turns items, links and what the event store holds into a list of actions; an engine that executes the actions through a small `EventStoring` protocol; the real EventKit adapter behind it; and a scoped wrapper that refuses any write outside the chosen calendar or list.
3. Let EventKit's own change notifications drive two-way sync.

## Decision
Option 2.
- **Planner.** `SyncPlanner.plan(items:links:snapshot:settings:)` is pure. Per item it decides create, update, remove, adopt an edit made in Calendar, mark completed, mark removed by the user, or skip. Preview is the plan, shown and not run.
- **Hash.** Each link stores a hash and the fields of the last synced state. An entry whose fields differ from that state was edited by the user (adopted as locked values); an item whose rendering differs from it needs an update. Same hash means do nothing, which makes a repeated sync write nothing.
- **Scope.** `ScopedEventStore` wraps any `EventStoring` with the chosen calendar and list identifiers. It refuses every create, update and delete whose target is not in them, and refuses all event writes when no calendar is chosen. Only entries listed in `sync_links` can be updated or removed, never one found by searching.
- **Adapter.** `EventKitStore` implements `EventStoring` over `EKEventStore` (full access to events and reminders). It lists writable calendars and lists with their account names and never creates a calendar.
- **Completion.** Items have no done status, so completion in Reminders is a link state shown on the item; the reminder is left completed.

## Consequences
- Easier: the whole sync is tested with a fake store; a preview cannot write by construction; the scope rule is one small, heavily tested type.
- Harder: the real adapter and the permission prompts are only checked by hand; the hash must cover every synced field (a new field means a new hash version).
- Revisit: recurring events, attendees, and two-way import of events Memorri did not make.
