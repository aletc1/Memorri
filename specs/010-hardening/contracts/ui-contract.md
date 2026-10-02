# UI contract: hardening (spec 010)

1. **Item detail** (possibly cancelled): an orange block `Possibly cancelled: it was not in the last 2 captures of this calendar` with the date of the last capture that showed it and the dates of the captures that did not (shown with their dates), and two buttons, `Cancelled` and `Still happening`. The Inbox row shows the reason `Possibly cancelled`.
2. **Settings > General**: `Open Memorri at login` (switch; note and `Open System Settings` when approval is pending), `Notify me when new items arrive` (switch, on by default; permission state and `Open System Settings` when macOS refuses).
3. **Settings > Storage**: `Export items…` (save panel, shows the count), `Back up library…` (a sheet: both sizes, `Include capture pictures` on by default, progress, Cancel; the note that backups are not encrypted), `Restore from backup…` (open panel, validation result, what will be replaced, `Restore and restart`, `Cancel restore` while it is staged; a backup without pictures says `This backup has no capture pictures`), the list of safety copies with size and `Delete`.
4. **Settings > Diagnostics**: versions, permissions, queue counts and failure reasons, sync state, storage use, and `Save report…`. No item text anywhere.
5. **Notification**: `Memorri` / `3 new items, 1 needs review` (adds `, 1 possibly cancelled` when there are some); a click opens the Items window on the Inbox, or on all items when none need review.
6. **App icon**: the brain on a rounded blue square in Finder, Login Items, privacy lists and notifications.
