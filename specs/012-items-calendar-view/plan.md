# Implementation Plan: See items on a calendar, with a one-row header

**Branch**: `012-items-calendar-view` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

## Summary
Pure `ItemCalendar` in `MemorriCore` turns the visible rows into a `MonthGrid` (pinning, order, undated). The app gets a `CalendarMonthView` (SwiftUI `Grid`) next to the list, a view switch, and a rebuilt one-row header with a Show menu, icon actions and an icon Undo. No calendar package (ADR 0024).

## Technical Context
**Language/Version**: Swift 6, SwiftUI plus AppKit, macOS 26+
**Primary Dependencies**: none new (Foundation `Calendar`)
**Storage**: none new; two UserDefaults preferences
**Testing**: Swift Testing in `MemorriCoreTests` (`ItemCalendarTests`); manual run for the UI
**Project Type**: desktop-app
**Performance Goals**: grid for 5,000 items under 200 ms (SC-003)
**Constraints**: local only; no PII in tests; one selection shared by list and calendar
**Scale/Scope**: one core file, three app views, one view model change

## Constitution Check
Local-first: no network. Evidence/user-wins: no change to items. Test-first: core logic tested before the views. Decisions recorded: ADR 0024. Pass.

## Project Structure
```text
specs/012-items-calendar-view/  spec, plan, research, data-model, contracts/ui-contract.md, quickstart, tasks
Packages/MemorriCore/Sources/MemorriCore/Reconciliation/ItemCalendar.swift
Packages/MemorriCore/Tests/MemorriCoreTests/ItemCalendarTests.swift
App/Windows/ItemsView.swift (header, switch), ItemsToolbar.swift, CalendarMonthView.swift, ItemsViewModel.swift
```
