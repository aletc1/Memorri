import CoreGraphics
import MemorriCore
import Observation
import SwiftUI

/// A decoded picture handed across actors; it is never changed after it is made.
final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// The whole capture of a sighting with its read lines, for the sheet that outlines the cited ones.
struct WholeCapture: @unchecked Sendable {
    let picture: CGImage
    let lines: [RecognisedLine]
}

/// The state of the Items window: the list as the store observes it, the selection, the open item and what the user asked for.
/// The rules (filters, order, which buttons are enabled) are in `ItemListModel`; every change runs in the core off the main actor.
@MainActor
@Observable
final class ItemsViewModel {
    /// A merge that needs the user to say which locked value stays (FR-013).
    struct LockSheet: Identifiable {
        let id = UUID()
        let keep: String
        let other: String
        let choices: [LockChoice]
    }

    private let environment: AppEnvironment
    var filter = ItemFilter()
    private(set) var rows: [ItemRow] = []
    private(set) var contexts: [ContextRecord] = []
    var selection: Set<String> = []
    private(set) var detail: ItemDetail?
    /// The saved cut-outs of the open item, newest first.
    private(set) var evidence: [EvidenceRecord] = []
    private let cutOuts = NSCache<NSString, ImageBox>()
    private(set) var undoTarget: OperationSummary?
    var message: String?
    var lockSheet: LockSheet?
    private var observing: Task<Void, Never>?

    /// The left pane: the list or the month calendar (spec 012). Both views show `visibleRows` and share `selection`.
    enum ViewMode: String { case list, calendar }
    private static let viewModeKey = "items.viewMode"
    private static let monthKey = "items.month"

    var viewMode: ViewMode = .list {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
            if viewMode == .calendar { showMonthOfSelection() }
        }
    }
    /// The first day of the month the calendar shows.
    private(set) var month = ItemCalendar.firstOfMonth(ItemCalendar.today())

    init(environment: AppEnvironment) {
        self.environment = environment
        cutOuts.countLimit = 100
        let defaults = UserDefaults.standard
        viewMode = defaults.string(forKey: Self.viewModeKey).flatMap(ViewMode.init(rawValue:)) ?? .list
        if let saved = defaults.string(forKey: Self.monthKey).flatMap({ CalendarDay(monthText: $0) }) { month = saved }
    }

    var grid: MonthGrid { ItemCalendar.grid(rows: visibleRows, month: month, today: ItemCalendar.today(), firstWeekday: Calendar.current.firstWeekday) }

    func shiftMonth(_ count: Int) { setMonth(ItemCalendar.shift(month, by: count)) }
    func goToToday() { setMonth(ItemCalendar.firstOfMonth(ItemCalendar.today())) }

    private func setMonth(_ value: CalendarDay) {
        month = value
        UserDefaults.standard.set(value.monthText, forKey: Self.monthKey)
    }

    /// Moves the calendar to the month of the one selected item, so choosing it elsewhere (search, the menu) shows it.
    private func showMonthOfSelection() {
        guard selection.count == 1, let row = selectedRows.first, let target = ItemCalendar.month(of: row.item) else { return }
        if target != month { setMonth(target) }
    }

    /// A click on a chip selects it alone; Command-click adds or removes it, so two items can be merged from the calendar.
    func choose(_ id: String, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    // MARK: Reading

    /// What is typed in the window's search field; the list shows the items that match, best first (spec 007).
    var searchText = "" { didSet { if searchText != oldValue { runSearch() } } }
    private var searchIDs: [String]?
    private var searching: Task<Void, Never>?

    var visibleRows: [ItemRow] { ItemListModel.restrict(ItemListModel.visible(rows, filter: filter), to: searchIDs) }

    /// Asks the core which items match; every item, dismissed too, so that the list's own filters decide what shows.
    private func runSearch() {
        searching?.cancel()
        let query = SearchQuery(text: searchText, includeDismissed: true)
        guard query.isSearchable, let service = environment.search else { searchIDs = nil; return }
        searching = Task { [weak self] in
            let ids = try? await service.itemIDs(matching: query)
            guard !Task.isCancelled, let self else { return }
            self.searchIDs = ids ?? []
        }
    }
    /// All rows, not only the visible ones: a dismissed item stays selected (and can be restored) after the filter hides it.
    var selectedRows: [ItemRow] { rows.filter { selection.contains($0.item.id) } }
    var canMerge: Bool { ItemListModel.canMerge(selectedRows) }
    var canApprove: Bool { ItemListModel.canApprove(selectedRows) }
    /// How many items the Inbox lists with the kind and context filters as they are (FR-017).
    var inboxCount: Int { ItemListModel.inboxCount(rows, filter: filter) }
    var statusAction: ItemListModel.StatusAction? { ItemListModel.statusAction(for: selectedRows) }
    var isAvailable: Bool { environment.items != nil }

    // MARK: Calendar sync (spec 009)

    /// Where the open item is in Calendar or Reminders, or why not; nil when sync has nothing to say about it.
    func syncLine(for item: Item) -> (text: String, canSyncAgain: Bool)? {
        guard let store = environment.sync?.store else { return nil }
        let link = try? store.link(itemID: item.id)
        guard let text = SyncWords.itemLine(item: item, link: link, enabled: store.enabled, now: Date()) else { return nil }
        return (text, link?.state == .removedByUser)
    }

    /// The user deleted the entry and wants it back: the link is forgotten and the next sync writes it again.
    func syncAgain(_ item: Item) {
        guard let sync = environment.sync else { return }
        try? sync.store.syncAgain(itemID: item.id)
        Task { await sync.coordinator.changed() }
        syncRefresh += 1
    }
    private(set) var syncRefresh = 0

    func contextName(_ id: String?) -> String? { id.flatMap { id in contexts.first { $0.id == id }?.name } }

    func title(of id: String) -> String { rows.first { $0.item.id == id }?.item.title ?? "Another item" }

    func start() {
        contexts = (try? environment.contexts?.all()) ?? []
        guard observing == nil, let store = environment.items else { return }
        let stream = store.observeItems(status: [.active, .dismissed])
        observing = Task { [weak self] in
            for await rows in stream { self?.apply(rows) }
        }
    }

    /// Selects an item. When the list is not loaded yet (the window was just opened), the choice waits for it.
    func select(_ id: String) {
        if rows.contains(where: { $0.item.id == id }) { selection = [id]; pendingSelection = nil; showMonthOfSelection() } else { pendingSelection = id }
    }

    private var pendingSelection: String?

    private func apply(_ rows: [ItemRow]) {
        self.rows = rows
        if !searchText.isEmpty { runSearch() }
        if let pending = pendingSelection, rows.contains(where: { $0.item.id == pending }) { selection = [pending]; pendingSelection = nil; showMonthOfSelection() }
        selection.formIntersection(Set(rows.map(\.item.id)))
        Task { await refresh() }
    }

    func selectionChanged() { Task { await refresh() } }

    private func refresh() async {
        await loadDetail()
        await loadUndoTarget()
    }

    private func loadDetail() async {
        guard selection.count == 1, let id = selection.first, let store = environment.items else { detail = nil; evidence = []; return }
        detail = try? await Task.detached { try store.detail(itemID: id) }.value
        if let writer = environment.evidenceWriter { _ = await writer.backfill(itemID: id) }
        if let evidenceStore = environment.evidenceStore {
            evidence = (try? await Task.detached { try evidenceStore.evidence(itemID: id) }.value) ?? []
        } else {
            evidence = []
        }
    }

    private func loadUndoTarget() async {
        guard let log = environment.operationLog else { undoTarget = nil; return }
        let recent = (try? await Task.detached { try log.recent() }.value) ?? []
        undoTarget = ItemListModel.undoTarget(in: recent)
    }

    // MARK: Evidence images

    /// The saved cut-out, decoded off the main actor and kept in memory (100 images).
    func cutOut(_ record: EvidenceRecord) async -> CGImage? {
        let key = record.id as NSString
        if let hit = cutOuts.object(forKey: key) { return hit.image }
        guard let store = environment.evidenceStore else { return nil }
        guard let box = await Task.detached(operation: { store.image(record).map(ImageBox.init) }).value else { return nil }
        cutOuts.setObject(box, forKey: key)
        return box.image
    }

    /// The whole capture, nil once the picture is no longer stored.
    func wholeCapture(imageID: String) async -> WholeCapture? {
        guard let store = environment.evidenceStore else { return nil }
        return await Task.detached { (try? store.capture(imageID: imageID)).flatMap { $0 }.map { WholeCapture(picture: $0.picture, lines: $0.lines) } }.value
    }

    // MARK: Changing

    private func run(_ work: @escaping @Sendable (ItemOperations) throws -> Void) async {
        guard let operations = environment.itemOperations else { return }
        message = nil
        do { try await Task.detached { try work(operations) }.value } catch { message = Self.text(for: error) }
        await refresh()
    }

    func merge() async {
        let chosen = selectedRows
        guard chosen.count == 2 else { return }
        let ordered = chosen.sorted { $0.sightingCount > $1.sightingCount }
        await merge(keep: ordered[0].item.id, other: ordered[1].item.id, choices: [:])
    }

    func merge(keep: String, other: String, choices: [ItemField: String]) async {
        guard let operations = environment.itemOperations, let store = environment.items else { return }
        message = nil
        do {
            try await Task.detached { _ = try operations.merge(keep, other, lockChoices: choices) }.value
            selection = [keep]
        } catch ItemOperationError.needsLockChoice(let fields) {
            let details = try? await Task.detached { (try store.detail(itemID: keep), try store.detail(itemID: other)) }.value
            if let details {
                lockSheet = LockSheet(keep: keep, other: other, choices: ItemListModel.lockChoices(for: fields, keep: details.0, other: details.1))
            }
        } catch {
            message = Self.text(for: error)
        }
        await refresh()
    }

    func resolveLockSheet(_ sheet: LockSheet, picked: [ItemField: String]) async {
        lockSheet = nil
        await merge(keep: sheet.keep, other: sheet.other, choices: picked)
    }

    /// Approves the selected items. In the Inbox the selection moves on to the next item so the user can keep going with the keyboard.
    func approve() async {
        guard canApprove else { return }
        let ids = selectedRows.map(\.item.id)
        let next = filter.scope == .inbox ? nextSelection(leaving: Set(ids)) : nil
        await run { operations in
            for id in ids { _ = try operations.approve(id) }
        }
        if let next { selection = next }
    }

    /// `Still happening` on a possibly cancelled item (spec 010).
    func stillHappening(_ id: String) async { await run { operations in _ = try operations.confirmStillHappening(id) } }

    /// `Cancelled`: the item is dismissed like any other (sync removes its entry; Undo brings it back).
    func cancelled(_ id: String) async { await run { operations in _ = try operations.dismiss(id) } }

    /// The item after the selected ones in the list, else the one before; nothing when the list would be empty.
    private func nextSelection(leaving ids: Set<String>) -> Set<String> {
        let list = visibleRows.map(\.item.id)
        guard let last = list.lastIndex(where: ids.contains), let first = list.firstIndex(where: ids.contains) else { return [] }
        if let after = list[(last + 1)...].first(where: { !ids.contains($0) }) { return [after] }
        if let before = list[..<first].last(where: { !ids.contains($0) }) { return [before] }
        return []
    }

    func dismissOrRestore() async {
        guard let action = statusAction else { return }
        let ids = selectedRows.map(\.item.id)
        await run { operations in
            for id in ids {
                if action == .dismiss { _ = try operations.dismiss(id) } else { _ = try operations.restore(id) }
            }
        }
    }

    func undoLast() async {
        if let target = undoTarget { await undo(target.id) }
    }

    func undo(_ operationID: String) async {
        guard let operations = environment.itemOperations else { return }
        message = nil
        do {
            switch try await Task.detached(operation: { try await operations.undo(operationID) }).value {
            case .undone: break
            case .partly(_, let reason): message = "Partly undone: \(reason)"
            case .impossible(let reason): message = "Cannot undo: \(reason)"
            }
        } catch {
            message = Self.text(for: error)
        }
        await refresh()
    }

    /// Sets a field of the open item to the user's value. Returns why it was refused, to show next to the field, or nil when it was saved.
    func edit(field: ItemField, value: JSONValue) async -> String? {
        guard let id = detail?.item.id, let operations = environment.itemOperations else { return "Editing is not available right now." }
        do {
            try await Task.detached { _ = try operations.edit(id, field: field, value: value) }.value
        } catch {
            return Self.text(for: error)
        }
        await refresh()
        return nil
    }

    /// The same for text the user typed: it is read in the item's zone first.
    func edit(field: ItemField, text: String) async -> String? {
        guard let zone = detail?.item.timezone else { return nil }
        switch ItemListModel.parse(text, field: field, timezone: zone) {
        case .failure(let failure): return failure.message
        case .success(let value): return await edit(field: field, value: value)
        }
    }

    func unlock(_ field: ItemField) async {
        guard let id = detail?.item.id else { return }
        await run { _ = try $0.unlock(id, field: field) }
    }

    func split(_ sightings: [String]) async {
        guard let id = detail?.item.id, let operations = environment.itemOperations else { return }
        message = nil
        do {
            let result = try await Task.detached { try operations.split(id, sightings: sightings) }.value
            selection = [result.newItem]
        } catch {
            message = Self.text(for: error)
        }
        await refresh()
    }

    func mergeDuplicate(_ other: String) async {
        guard let id = detail?.item.id else { return }
        await merge(keep: id, other: other, choices: [:])
    }

    func markDifferent(_ other: String) async {
        guard let id = detail?.item.id else { return }
        await run { _ = try $0.markDifferent(id, other) }
    }

    static func text(for error: Error) -> String {
        switch error as? ItemOperationError {
        case .notFound?: "That item no longer exists."
        case .merged?: "That item was merged into another one; select the other one."
        case .notLocked?: "That field is not locked."
        case .wrongStatus?: "That is not possible in the item's current state."
        case .invalidValue?: "That value is not valid."
        case .startAfterEnd?: "The start cannot be after the end."
        case .emptyTitle?: "The title cannot be empty."
        case .invalidSightings?: "Check at least one sighting and leave at least one unchecked."
        case .sameItem?: "Select two different items."
        case .noReconciler?: "Matching is not available right now."
        case .needsLockChoice?: "Both items have a value you set; choose which one to keep."
        case nil: "Something went wrong: \(error.localizedDescription)"
        }
    }
}
