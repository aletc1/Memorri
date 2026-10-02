# Implementation Plan: Sync items to Calendar and Reminders

**Branch**: `009-eventkit-sync` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

## Summary
A pure `SyncPlanner` turns ready items, `sync_links` and what the event store holds into actions (create, update, remove, adopt an outside edit, complete, mark removed). A `SyncEngine` runs them only through a `ScopedEventStore` that refuses any write outside the calendar and list the user chose (the user keeps Personal and Work untouched and makes a `Memorri` calendar). `EventKitStore` is the real adapter; a `SyncCoordinator` runs sync at start, after changes (debounced) and on `Sync now`, after a first previewed sync. ADR 0026.

## Technical Context
**Language/Version**: Swift 6, SwiftUI plus AppKit, macOS 26+
**Primary Dependencies**: EventKit (system); no package
**Storage**: migration v11 (`sync_links`, `sync_runs`); settings keys
**Testing**: Swift Testing with a fake `EventStoring`; real EventKit checked by hand (permissions)
**Project Type**: desktop-app
**Performance Goals**: 1,000 items synced in under 60 s on a local calendar, off the main actor
**Constraints**: writes only to the chosen calendar and list; entries Memorri did not make never touched; local only
**Scale/Scope**: about seven core files, one adapter, one settings tab, an Info.plist change, a URL scheme

## Constitution Check
I Local-first: only the user's own calendar store. II Evidence: notes list the evidence and link back. III Idempotent: hash and links make a repeated sync write nothing. IV User wins: outside edits are adopted as locked values; deleted entries are not recreated; Inbox items do not sync until approved. V Raw data: untouched. VI Test-first: planner, scope and engine tested with a fake store before the adapter; no prompt change. VII Incremental: runnable at each story. VIII ADR 0026. Pass.

## Project Structure
```text
specs/009-eventkit-sync/  spec, plan, research, data-model, contracts/, quickstart, tasks
Packages/MemorriCore/Sources/MemorriCore/Sync/
  SyncTypes.swift  SyncRender.swift  SyncPlanner.swift  ScopedEventStore.swift  SyncStore.swift  SyncEngine.swift  SyncCoordinator.swift
Packages/MemorriCore/Sources/MemorriCore/Storage/Migrations.swift (v11)
Packages/MemorriCore/Tests/MemorriCoreTests/Sync*Tests.swift
App/Sync/EventKitStore.swift   App/Windows/CalendarSyncView.swift (replaces the placeholder tab)   App/Info.plist (usage strings, URL scheme)
App/AppEnvironment.swift (wiring, deep link)   App/Windows/ItemDetailView.swift (sync row)
```
