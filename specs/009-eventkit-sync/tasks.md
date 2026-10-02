# Tasks: sync (spec 009)

## Phase 1: Foundation
- [x] T001 Migration v11 `sync_links`, `sync_runs`; storage test (Storage/Migrations.swift, Tests/StorageDatabaseTests.swift)
- [x] T002 [P] Types: `SyncEntryKind`, `RenderedEntry`, `StoredEntry`, `SyncContainer`, `SyncAccess`, `EventStoring`, `SyncAction`, `SyncSettings` (Sync/SyncTypes.swift)
- [x] T003 `SyncStore` (links, runs, settings keys) with tests first (Sync/SyncStore.swift, Tests/SyncStoreTests.swift)

## Phase 2: US1 and the scope rule (US1, FR-019 to FR-021)
- [x] T004 [US1] Tests: scoped store refuses every write outside the chosen calendar and list, refuses events with no calendar, refuses unknown ids, allows the chosen ones (Tests/ScopedEventStoreTests.swift)
- [x] T005 [US1] `ScopedEventStore` (Sync/ScopedEventStore.swift)
- [x] T006 [US1] Target choice: preselect `Memorri`, notice for non-empty calendars (pure `SyncTargets`), tests (Sync/SyncTargets.swift, Tests/SyncTargetsTests.swift)

## Phase 3: US2 render and plan
- [x] T007 [US2] Tests then `SyncRender` (titles with context, event and reminder fields, notes, link, hash and its stability) (Tests/SyncRenderTests.swift, Sync/SyncRender.swift)
- [x] T008 [US2] Tests then `SyncPlanner` (create ready items, skip Inbox, update on change, merged and dismissed removal, undated, 90-day range, no duplicates on a second plan) (Tests/SyncPlannerTests.swift, Sync/SyncPlanner.swift)
- [x] T009 [US2] Tests then `SyncEngine` with a fake store (links recorded, second run writes nothing, failure of one item does not stop the others, runs recorded) (Tests/SyncEngineTests.swift, Sync/SyncEngine.swift)

## Phase 4: US3 outside edits
- [x] T010 [US3] Planner: adopt edits, completion, deletion, moved-calendar; tests (Tests/SyncOutsideEditsTests.swift)
- [x] T011 [US3] Engine: adopt through `ItemOperations.edit` (locks), link states; tests

## Phase 5: US4 preview and runs, coordinator
- [x] T012 [US4] Preview writes nothing (counting test); `SyncCoordinator` (first run held, debounce, no overlap) with tests (Sync/SyncCoordinator.swift, Tests/SyncCoordinatorTests.swift)

## Phase 6: App
- [ ] T013 `EventKitStore` adapter; Info.plist usage strings and URL scheme; wiring and deep link (App/Sync/EventKitStore.swift, App/Info.plist/project.yml, App/AppEnvironment.swift)
- [ ] T014 Settings > Calendar sync tab: access, targets, switch, Preview sheet, Sync now, runs, remove entries on switching off (App/Windows/CalendarSyncView.swift)
- [ ] T015 Item detail sync row and `Sync again`; item history words (App/Windows/ItemDetailView.swift)

## Phase 7: Polish
- [ ] T016 Scale test (1,000 items), logging without content, full suite, docs (DEVELOPER.md, roadmap, CLAUDE.md, pr-description)
- [ ] T017 Run in the app against calendars named `Memorri` (quickstart); Personal and Work unchanged
