import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// When sync runs by itself and when it waits (spec 009 FR-012).
@Suite struct SyncCoordinatorTests {
    private let clock = Date(timeIntervalSince1970: 1_791_961_200 + 86_400)

    /// A store that is slow to create and notes whether two creates ever overlapped.
    private final class SlowStore: EventStoring, @unchecked Sendable {
        let base = FakeEventStore()
        private let lock = NSLock()
        private var active = 0
        private(set) var overlapped = false
        func access(for kind: SyncEntryKind) -> SyncAccess { base.access(for: kind) }
        func requestAccess(for kind: SyncEntryKind) async -> SyncAccess { await base.requestAccess(for: kind) }
        func containers(for kind: SyncEntryKind) -> [SyncContainer] { base.containers(for: kind) }
        func entry(id: String, kind: SyncEntryKind) -> StoredEntry? { base.entry(id: id, kind: kind) }
        func create(_ entry: RenderedEntry, in containerID: String) throws -> String {
            lock.withLock { active += 1; if active > 1 { overlapped = true } }
            Thread.sleep(forTimeInterval: 0.02)
            defer { lock.withLock { active -= 1 } }
            return try base.create(entry, in: containerID)
        }
        func update(id: String, _ entry: RenderedEntry) throws { try base.update(id: id, entry) }
        func delete(id: String, kind: SyncEntryKind) throws { try base.delete(id: id, kind: kind) }
    }

    private func setup(events: any EventStoring, enabled: Bool = true, confirmed: Bool = false) throws -> (ReconcileFixture, SyncStore, SyncCoordinator) {
        let fixture = try ReconcileFixture()
        for (n, title) in ["Standup", "Budget review"].enumerated() {
            try fixture.write { try $0.execute(sql: """
                INSERT INTO items (id, kind, family, status, title, timezone, confidence, first_seen, last_seen, created_at, updated_at, start_at, end_at, needs_review)
                VALUES (?, 'appointment', 'event', 'active', ?, 'UTC', 0.9, datetime('now'), datetime('now'), datetime('now'), datetime('now'), ?, ?, 0)
                """, arguments: ["i\(n)", title, ReconcileFixture.minutes(60 * (n + 1)), ReconcileFixture.minutes(60 * (n + 1) + 30)]) }
        }
        let store = SyncStore(database: fixture.database, settings: FakeSettingsStore())
        store.setCalendarID("cal-memorri"); store.setListID("list-memorri"); store.setEnabled(enabled); store.setFirstSyncConfirmed(confirmed)
        let engine = SyncEngine(database: fixture.database, store: store, events: events, operations: ItemOperations(database: fixture.database, now: { clock }), now: { clock })
        return (fixture, store, SyncCoordinator(engine: engine, store: store, debounce: .milliseconds(60)))
    }

    private func settle(_ coordinator: SyncCoordinator, within seconds: Double = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if await !coordinator.isRunning { return }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func nothingRunsByItselfBeforeTheFirstSyncNowOrWhileSyncIsOff() async throws {
        let events = FakeEventStore()
        let (fixture, _, coordinator) = try setup(events: events); defer { fixture.cleanUp() }
        await coordinator.start(); await coordinator.changed()
        try await Task.sleep(for: .milliseconds(250))
        #expect(events.writes.isEmpty)

        let off = FakeEventStore()
        let (f2, _, c2) = try setup(events: off, enabled: false, confirmed: true); defer { f2.cleanUp() }
        await c2.start(); await c2.changed()
        try await Task.sleep(for: .milliseconds(250))
        #expect(off.writes.isEmpty)
    }

    @Test func syncNowRunsAtOnceAndConfirmsTheFirstSync() async throws {
        let events = FakeEventStore()
        let (fixture, store, coordinator) = try setup(events: events); defer { fixture.cleanUp() }
        let preview = await coordinator.preview()
        #expect(preview.run.preview && preview.run.created == 2 && events.writes.isEmpty && !store.firstSyncConfirmed)
        let outcome = await coordinator.syncNow()
        #expect(outcome.run.created == 2 && events.writes.count == 2 && store.firstSyncConfirmed)
        #expect(await coordinator.lastOutcome == outcome)
    }

    @Test func aBurstOfChangesRunsOnceAfterTheDebounceAndStartRunsAfterConfirmation() async throws {
        let events = FakeEventStore()
        let (fixture, _, coordinator) = try setup(events: events, confirmed: true); defer { fixture.cleanUp() }
        let seen = OutcomeCounter()
        await coordinator.onOutcome { _ in seen.add() }
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(events.writes.count == 2 && seen.count == 1)

        try fixture.write { try $0.execute(sql: "UPDATE items SET place = 'Room 9' WHERE id = 'i0'") }
        for _ in 0..<5 { await coordinator.changed(); try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.count == 2 && events.writes.filter { $0.op == "update" }.count == 1)
    }

    @Test func runsNeverOverlap() async throws {
        let events = SlowStore()
        let (fixture, _, coordinator) = try setup(events: events); defer { fixture.cleanUp() }
        async let a = coordinator.syncNow(), b = coordinator.syncNow()
        let outcomes = await [a, b]
        #expect(!events.overlapped)
        #expect(outcomes.map(\.run.created).sorted() == [0, 2] && events.base.entries.count == 2)   // the second run found nothing left to write
    }

    @Test func cancellingThePendingRunStopsIt() async throws {
        let events = FakeEventStore()
        let (fixture, _, coordinator) = try setup(events: events, confirmed: true); defer { fixture.cleanUp() }
        await coordinator.changed(); await coordinator.cancelPending()
        try await Task.sleep(for: .milliseconds(250))
        #expect(events.writes.isEmpty)
    }
}

private final class OutcomeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
