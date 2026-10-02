import Foundation
import MemorriCore
import Observation

/// The sync pieces the app holds (spec 009).
struct SyncServices {
    let store: SyncStore
    let engine: SyncEngine
    let coordinator: SyncCoordinator
    let eventKit: EventKitStore
}

/// What Settings > Calendar sync shows and does: access, the two targets, the switch, the preview, the runs.
@MainActor @Observable
final class CalendarSyncModel {
    struct MoveRequest: Identifiable { let id = UUID(); let kind: SyncEntryKind; let newID: String; let count: Int; let newName: String }

    private let services: SyncServices
    private let items: ItemStore?

    private(set) var eventAccess = SyncAccess.notDetermined
    private(set) var reminderAccess = SyncAccess.notDetermined
    private(set) var calendars: [SyncContainer] = []
    private(set) var lists: [SyncContainer] = []
    private(set) var calendarID: String?
    private(set) var listID: String?
    private(set) var enabled = false
    private(set) var confirmed = false
    private(set) var running = false
    private(set) var runs: [SyncRunRecord] = []
    private(set) var outcome: SyncOutcome?
    var previewGroups: [SyncWords.PreviewGroup]?
    var previewIsFirst = false
    var moveRequest: MoveRequest?
    var message: String?
    private(set) var now = Date()
    /// Whether the chosen calendar already holds events, found off the main thread.
    private(set) var calendarHoldsOthers = false

    init(services: SyncServices, items: ItemStore?) {
        self.services = services; self.items = items
    }

    /// Reads everything again: access, the calendars and lists, the choices and the runs.
    func reload() {
        now = Date()
        eventAccess = services.eventKit.access(for: .event)
        reminderAccess = services.eventKit.access(for: .reminder)
        calendars = services.eventKit.containers(for: .event)
        lists = services.eventKit.containers(for: .reminder)
        let store = services.store
        // Nothing is chosen for the user except a calendar or list named Memorri, found when no choice was made yet.
        if store.calendarID == nil, let found = SyncTargets.preselect(calendars) { store.setCalendarID(found) }
        if store.listID == nil, let found = SyncTargets.preselect(lists) { store.setListID(found) }
        calendarID = store.calendarID; listID = store.listID
        enabled = store.enabled; confirmed = store.firstSyncConfirmed
        runs = (try? store.runs()) ?? []
        checkCalendarNotice()
    }

    private var checkedCalendar: String?
    private func checkCalendarNotice() {
        guard let id = calendarID, eventAccess == .allowed else { calendarHoldsOthers = false; checkedCalendar = nil; return }
        guard id != checkedCalendar else { return }
        checkedCalendar = id
        let eventKit = services.eventKit
        Task.detached {
            let holds = eventKit.holdsEntries(inContainer: id, kind: .event)
            await MainActor.run { [weak self] in if self?.calendarID == id { self?.calendarHoldsOthers = holds } }
        }
    }

    /// The Refresh button, and what runs when Calendar changed or the app came back to the front: look for new calendars and lists again.
    func refresh() {
        services.eventKit.refreshSources()
        reload()
    }

    /// Listens for finished runs so the tab stays current while it is open.
    func follow() async {
        await services.coordinator.onOutcome { [weak self] outcome in
            Task { @MainActor in self?.finished(outcome) }
        }
    }

    private func finished(_ value: SyncOutcome) {
        if !value.run.preview { outcome = value }
        reload()
    }

    // MARK: Derived

    var calendarMissing: Bool { calendarID != nil && !SyncTargets.isStillAvailable(calendarID, in: calendars) && eventAccess == .allowed }
    var listMissing: Bool { listID != nil && !SyncTargets.isStillAvailable(listID, in: lists) && reminderAccess == .allowed }
    var calendarNotice: String? {
        guard calendarHoldsOthers, let chosen = calendars.first(where: { $0.id == calendarID }) else { return nil }
        return SyncTargets.notice(for: SyncContainer(id: chosen.id, name: chosen.name, account: chosen.account, kind: .event, holdsOtherEntries: true))
    }
    var listNotice: String? { lists.first { $0.id == listID }.flatMap(SyncTargets.notice) }
    var canEnable: Bool {
        (calendarID != nil && eventAccess == .allowed && !calendarMissing) || (listID != nil && reminderAccess == .allowed && !listMissing)
    }
    var statusLine: String { SyncWords.status(enabled: enabled, confirmed: confirmed, outcome: outcome, lastRun: runs.first { !$0.preview }, now: now) }

    func accessText(_ kind: SyncEntryKind) -> String {
        switch kind == .event ? eventAccess : reminderAccess {
        case .allowed: "Allowed"
        case .notDetermined: "Not asked yet"
        case .denied: "Not allowed"
        }
    }

    func access(_ kind: SyncEntryKind) -> SyncAccess { kind == .event ? eventAccess : reminderAccess }

    // MARK: Actions

    func requestAccess(_ kind: SyncEntryKind) {
        Task { _ = await services.eventKit.requestAccess(for: kind); reload() }
    }

    func chooseCalendar(_ id: String?) { choose(.event, id) }
    func chooseList(_ id: String?) { choose(.reminder, id) }

    /// A new target while Memorri's entries exist elsewhere asks first: they would move (FR-020).
    private func choose(_ kind: SyncEntryKind, _ id: String?) {
        let store = services.store
        let current = kind == .event ? store.calendarID : store.listID
        guard id != current else { return }
        let linked = ((try? store.links()) ?? [:]).values.filter { $0.kind == kind && [.synced, .completed, .failed].contains($0.state) }
        if let id, current != nil, !linked.isEmpty {
            let name = (kind == .event ? calendars : lists).first { $0.id == id }?.name ?? "the new target"
            moveRequest = MoveRequest(kind: kind, newID: id, count: linked.count, newName: name)
            return
        }
        apply(kind, id)
    }

    private func apply(_ kind: SyncEntryKind, _ id: String?) {
        if kind == .event { services.store.setCalendarID(id) } else { services.store.setListID(id) }
        reload()
        if enabled { Task { await services.coordinator.changed() } }
    }

    func confirmMove() {
        guard let request = moveRequest else { return }
        moveRequest = nil
        apply(request.kind, request.newID)
        Task { _ = await services.coordinator.syncNow(allowMove: true) }
    }

    func setEnabled(_ value: Bool) {
        if value {
            services.store.setEnabled(true)
            services.store.setFirstSyncConfirmed(false)
            reload()
            Task { await preview(first: true) }
        } else {
            services.store.setEnabled(false)
            services.store.setFirstSyncConfirmed(false)
            Task { await services.coordinator.cancelPending() }
            reload()
        }
    }

    /// Switching off with `Remove Memorri's entries`.
    func switchOff(removeEntries: Bool) {
        setEnabled(false)
        if removeEntries {
            let engine = services.engine
            Task.detached {
                let removed = engine.removeAllEntries()
                await MainActor.run { [weak self] in self?.message = "Removed \(removed) \(removed == 1 ? "entry" : "entries") Memorri had made."; self?.reload() }
            }
        }
    }

    func preview(first: Bool = false) async {
        message = nil
        running = true
        let result = await services.coordinator.preview()
        running = false
        previewIsFirst = first || !confirmed
        var titles: [String: String] = [:]
        for action in result.plan.actions { if let item = try? items?.item(id: action.itemID) { titles[action.itemID] = item.title } }
        if let problem = result.problem { message = SyncWords.problem(problem); previewGroups = nil; return }
        previewGroups = SyncWords.preview(result.plan, titles: titles)
        reload()
    }

    func syncNow() {
        previewGroups = nil
        running = true; message = nil
        Task {
            let result = await services.coordinator.syncNow()
            running = false
            if let problem = result.problem { message = SyncWords.problem(problem) }
            reload()
        }
    }

    func closePreview() { previewGroups = nil }

    var removalCount: Int { ((try? services.store.links()) ?? [:]).values.filter { [.synced, .completed, .failed].contains($0.state) }.count }
}
