# Core interfaces: sync (spec 009)

```swift
protocol EventStoring: Sendable            // what the engine needs of the system store
  func access() -> SyncAccess                         // events, reminders: notDetermined | allowed | denied
  func requestAccess() async -> SyncAccess
  func calendars() -> [SyncContainer]; func lists() -> [SyncContainer]      // writable, with account name
  func entry(id: String, kind: SyncEntryKind) -> StoredEntry?              // nil when gone
  func create(_ entry: RenderedEntry, in containerID: String) throws -> String
  func update(id: String, _ entry: RenderedEntry) throws
  func delete(id: String, kind: SyncEntryKind) throws
struct ScopedEventStore: EventStoring       // refuses writes outside calendarID / listID (ADR 0026)
struct EventKitStore: EventStoring          // the EKEventStore adapter (App)
enum SyncRender                              // Item + evidence + context -> RenderedEntry; hash
enum SyncPlanner                             // pure: items, links, snapshot, settings -> SyncPlan [SyncAction]
struct SyncEngine                            // run(plan) through the scoped store, records links and runs, adopts edits via ItemOperations
actor SyncCoordinator                        // start, debounce, Sync now, store-changed; never overlaps
struct SyncStore                             // sync_links, sync_runs, settings
```
SyncAction: `create(item)`, `update(item, fields)`, `remove(item, reason)`, `adopt(item, [field: value])`, `complete(item)`, `markRemovedByUser(item)`, `skip(item, reason)`.
