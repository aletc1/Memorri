# 6. EventKit sync targets

- Status: Accepted
- Date: 2026-09-29

## Context and problem
The user wants everything synced to macOS and iCloud. Calendars hold events only; tasks and reminders live in Reminders.

## Decision
Sync is one-way, from Memorri to the system. Appointments go to a chosen Calendar as EKEvent. Tasks and reminders go to a chosen Reminders list as EKReminder with EKAlarm. Settings has both pickers. sync_links maps entities to EventKit identifiers and stores a hash of the last synced state. Requires NSCalendarsFullAccessUsageDescription and NSRemindersFullAccessUsageDescription. Only items above the confidence threshold sync automatically.

## Consequences
Two permissions to request. Edits made in Calendar.app are detected and lock the affected fields. Sync is built last (spec 009).
