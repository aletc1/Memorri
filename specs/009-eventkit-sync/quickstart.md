# Quickstart: sync (spec 009)

1. `swift test --package-path Packages/MemorriCore --filter Sync` (render, hash, planner, scope, engine with a fake store).
2. Create a calendar named `Memorri` and a Reminders list named `Memorri` in Calendar and Reminders. Run Memorri, open Settings > Calendar sync, allow both, check both are preselected, switch on, read the preview, press `Sync now`.
3. In Calendar see the events in `Memorri` only; check Personal and Work are unchanged. Change an event's time in Calendar.app, sync: the item shows the time with a lock. Complete a reminder: the item says `Completed in Reminders`. Dismiss an item: its entry disappears.
