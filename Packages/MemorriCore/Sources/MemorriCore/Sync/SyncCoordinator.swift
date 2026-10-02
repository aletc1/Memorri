import Foundation
import os

/// Decides when a sync runs (spec 009 FR-012): at start, a short while after items change or Calendar changes, and on `Sync now`. Runs never
/// overlap, and a change that arrives during a run causes one more run. Nothing runs by itself while sync is off or before the user has seen a
/// preview and pressed `Sync now` for the first time.
public actor SyncCoordinator {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "sync")

    private let engine: SyncEngine
    private let store: SyncStore
    private let debounce: Duration
    private var onOutcome: (@Sendable (SyncOutcome) -> Void)?
    /// Each run or preview waits for the one before it, so they never overlap.
    private var tail: Task<Void, Never>?
    private var inFlight = 0
    private var debounceTask: Task<Void, Never>?
    public private(set) var lastOutcome: SyncOutcome?

    /// `debounce` groups changes: five seconds in the app.
    public init(engine: SyncEngine, store: SyncStore, debounce: Duration = .seconds(5)) {
        self.engine = engine; self.store = store; self.debounce = debounce
    }

    /// Called with the outcome of every run (and preview) so the Settings tab can show it.
    public func onOutcome(_ handler: (@Sendable (SyncOutcome) -> Void)?) { onOutcome = handler }

    public var isRunning: Bool { inFlight > 0 }

    /// Whether a sync may start without the user asking.
    var automatic: Bool { store.enabled && store.firstSyncConfirmed && (store.calendarID != nil || store.listID != nil) }

    // MARK: Triggers

    /// The app started: one run when sync is on and was already confirmed.
    public func start() {
        guard automatic else { return }
        Task { _ = await self.run(allowMove: false, confirm: false) }
    }

    /// An item became ready or changed, or Calendar or Reminders changed: a run follows after the debounce.
    public func changed() {
        guard automatic else { return }
        debounceTask?.cancel()
        let wait = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.runAutomatic()
        }
    }

    /// Stops a waiting run, for switching sync off.
    public func cancelPending() { debounceTask?.cancel(); debounceTask = nil }

    private func runAutomatic() async {
        debounceTask = nil
        guard automatic else { return }
        _ = await run(allowMove: false, confirm: false)
    }

    // MARK: On demand

    /// `Sync now`: runs at once, and the first one confirms that the user has seen a preview.
    @discardableResult
    public func syncNow(allowMove: Bool = false) async -> SyncOutcome {
        debounceTask?.cancel(); debounceTask = nil
        return await run(allowMove: allowMove, confirm: true)
    }

    /// Plans and writes nothing. It waits for a run in progress so the plan matches what that run left.
    public func preview() async -> SyncOutcome {
        let engine = engine
        let outcome = await serial { await engine.preview() }
        report(outcome)
        return outcome
    }

    private func run(allowMove: Bool, confirm: Bool) async -> SyncOutcome {
        let engine = engine, store = store
        let outcome = await serial {
            if confirm { store.setFirstSyncConfirmed(true) }
            return await engine.run(allowMove: allowMove)
        }
        report(outcome)
        return outcome
    }

    private func serial(_ work: @escaping @Sendable () async -> SyncOutcome) async -> SyncOutcome {
        let previous = tail
        let task = Task { () -> SyncOutcome in
            _ = await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        inFlight += 1
        let outcome = await task.value
        inFlight -= 1
        return outcome
    }

    private func report(_ outcome: SyncOutcome) {
        lastOutcome = outcome
        onOutcome?(outcome)
    }
}
