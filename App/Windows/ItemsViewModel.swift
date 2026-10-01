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

    init(environment: AppEnvironment) {
        self.environment = environment
        cutOuts.countLimit = 100
    }

    // MARK: Reading

    var visibleRows: [ItemRow] { ItemListModel.visible(rows, filter: filter) }
    /// All rows, not only the visible ones: a dismissed item stays selected (and can be restored) after the filter hides it.
    var selectedRows: [ItemRow] { rows.filter { selection.contains($0.item.id) } }
    var canMerge: Bool { ItemListModel.canMerge(selectedRows) }
    var statusAction: ItemListModel.StatusAction? { ItemListModel.statusAction(for: selectedRows) }
    var isAvailable: Bool { environment.items != nil }

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

    private func apply(_ rows: [ItemRow]) {
        self.rows = rows
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

    func editTitle(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = detail?.item, !trimmed.isEmpty, trimmed != item.title else { return }
        await run { _ = try $0.edit(item.id, field: .title, value: .string(trimmed)) }
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
        case .invalidSightings?: "Check at least one sighting and leave at least one unchecked."
        case .sameItem?: "Select two different items."
        case .noReconciler?: "Matching is not available right now."
        case .needsLockChoice?: "Both items have a value you set; choose which one to keep."
        case nil: "Something went wrong: \(error.localizedDescription)"
        }
    }
}
