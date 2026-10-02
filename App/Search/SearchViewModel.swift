import MemorriCore
import Observation
import SwiftUI

/// The state of the quick-search panel: what is typed, the filters, the answer for exactly that text, and the highlighted row. Every search runs
/// in the core off the main actor; a newer keystroke cancels the older search, so answers are never mixed.
@MainActor
@Observable
final class SearchViewModel {
    private let environment: AppEnvironment
    var text = "" { didSet { if text != oldValue { changed() } } }
    var kinds: Set<SearchQuery.Kinds> = [] { didSet { if kinds != oldValue { changed() } } }
    var context: SearchQuery.Context = .any { didSet { if context != oldValue { changed() } } }
    var dates: ClosedRange<Date>? { didSet { if dates != oldValue { changed() } } }
    var includeDismissed = false { didSet { if includeDismissed != oldValue { changed() } } }
    private(set) var results = SearchResults.empty
    private(set) var state = SearchState.ready
    private(set) var contexts: [ContextRecord] = []
    private(set) var isSlow = false
    var selection: Int?
    /// Moves forward each time the panel opens, so the field takes focus again.
    private(set) var focusToken = 0
    private var itemLimit = 20
    private var captureLimit = 20
    private var running: Task<Void, Never>?
    private var observing: Task<Void, Never>?

    init(environment: AppEnvironment) { self.environment = environment }

    var query: SearchQuery { SearchQuery(text: text, kinds: kinds, context: context, dates: dates, includeDismissed: includeDismissed) }
    var rows: [SearchPanelModel.Row] { SearchPanelModel.rows(results) }
    var message: String? { SearchPanelModel.message(for: query, results: results, state: state, contextName: contextName(contextID)) }
    func contextName(_ id: String?) -> String? { id.flatMap { id in contexts.first { $0.id == id }?.name } }

    /// The panel opens: a fresh field with the cursor in it. Filters stay as the user left them.
    func open() {
        focusToken += 1
        contexts = (try? environment.contexts?.all()) ?? []
        selection = nil
        observeLibrary()
        changed()
    }

    func close() { running?.cancel(); observing?.cancel(); observing = nil }

    func clearFilters() {
        var cleared = query
        cleared.clearFilters()
        kinds = cleared.kinds; context = cleared.context; dates = cleared.dates; includeDismissed = cleared.includeDismissed
    }
    var hasFilters: Bool { query.hasFilters }

    func toggle(_ kind: SearchQuery.Kinds) { if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) } }
    var activeFilterTexts: [String] { SearchPanelModel.filterTexts(query, contextName: contextName(contextID)) }
    private var contextID: String? { if case .one(let id) = context { id } else { nil } }

    func move(_ delta: Int) { selection = SearchPanelModel.move(from: selection, by: delta, count: rows.count) }

    func target() -> SearchPanelModel.Target? { SearchPanelModel.target(rows: rows, selection: selection ?? (rows.isEmpty ? nil : 0)) }

    func showMore(_ target: SearchPanelModel.Target) {
        if target == .showMoreItems { itemLimit += 20 } else { captureLimit += 20 }
        changed()
    }

    private func changed() {
        itemLimit = 20; captureLimit = 20
        run()
    }

    private func run() {
        running?.cancel()
        guard let service = environment.search else { return }
        let query = self.query, itemLimit = self.itemLimit, captureLimit = self.captureLimit
        guard query.isSearchable else { results = .empty; selection = nil; isSlow = false; return }
        running = Task { [weak self] in
            let slow = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { self?.isSlow = true }
            }
            let answer = try? await service.search(query, itemLimit: itemLimit, captureLimit: captureLimit)
            slow.cancel()
            guard !Task.isCancelled, let self else { return }
            self.isSlow = false
            if let answer { self.results = answer; self.clampSelection() }
        }
    }

    private func clampSelection() {
        if let selection, selection >= rows.count { self.selection = rows.isEmpty ? nil : rows.count - 1 }
    }

    /// Keeps an open panel current: the answer is asked for again when the library changes.
    private func observeLibrary() {
        guard observing == nil, let stream = environment.search?.changes() else { return }
        observing = Task { [weak self] in
            for await _ in stream { self?.run() }
        }
    }
}
