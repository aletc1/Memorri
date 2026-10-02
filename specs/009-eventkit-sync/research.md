# Research: sync to Calendar and Reminders (spec 009)

## R1. Access
Decision: `EKEventStore.requestFullAccessToEvents` and `requestFullAccessToReminders` (macOS 14+), with `NSCalendarsFullAccessUsageDescription` and `NSRemindersFullAccessUsageDescription` in `App/Info.plist` (via project.yml). The app is not sandboxed, so no entitlements are needed. Status is read with `EKEventStore.authorizationStatus(for:)` and re-read when the tab opens and before every run; a revoked grant stops sync without error text beyond the tab's message.

## R2. Targets and the scope rule
Decision: the pickers list `store.calendars(for: .event)` and `.reminder` where `allowsContentModifications`, each with its `source.title` (the account). A calendar named `Memorri` is preselected when it exists. Chosen identifiers are stored in settings (`calendarIdentifier`). `ScopedEventStore` (ADR 0026) is the only object the engine writes through.

## R3. Identity of entries
Decision: `EKEvent.eventIdentifier` and `EKReminder.calendarItemIdentifier` are stored in `sync_links`. An entry is found again by that identifier and must still be in the chosen calendar or list; otherwise it counts as removed or moved by the user. The calendar item's external identifier is not used (it changes across accounts).

## R4. What an entry holds
Decision: title `[Context] Title` (no prefix without context); event start and end in the item's zone (all-day events use `isAllDay`; no end means one hour for a timed event, the item's own end otherwise); location from the place; notes: a line `Made by Memorri`, the people, up to three evidence lines (`capture time, window`), and `memorri://item/<id>`. Reminder: title, due date components (date only for all-day), alarm at `remind` when set, notes as above. Reminders without a due date are written undated. A fixed `url` is not set (the notes link is enough).

## R5. Change detection
Decision: `SyncHash` over the rendered entry (title, start, end, all-day, location, notes, due, alarm) with a version number. Link stores the hash and the rendered fields. At sync: read the entry; if its current fields differ from the stored fields it was edited outside Memorri; each changed field among title, start, end, all-day, location (place), due is adopted as a locked user value with `ItemOperations.edit` (notes and alarm edits are not adopted; Memorri notes are rewritten only if the user did not change them). Then Memorri's own change, if any, is rendered on top of the adopted values.

## R6. Completion and deletion
Decision: a reminder with `isCompleted` true sets the link state `completed` and is never reopened. An entry that cannot be found, or is found in another calendar, sets the link state `removedByUser`; it is not recreated until the user presses `Sync again` on the item.

## R7. When sync runs
Decision: one `SyncCoordinator` actor runs a sync at start, after a short debounce (5 s) of changes to items (observed from `ItemStore`), on `Sync now`, and on `EKEventStoreChanged` (to notice edits in Calendar). Runs never overlap; changes during a run schedule another. The first run after switching on is held until the user has seen a preview and pressed `Sync now`.

## R8. Removal
Decision: a dismissed or merged-away item with a link has its entry deleted through the scoped store and the link state set to `removed`; restoring the item makes the planner create it again.

## R9. Date range
Decision: items whose moment is more than 90 days in the past are not written (an entry already written is left as it is). The tab states the range.

## R10. Deep link
Decision: `CFBundleURLTypes` registers `memorri`; `application(_:open:)` for `memorri://item/<id>` opens the Items window on that item through the existing `showItem`.
