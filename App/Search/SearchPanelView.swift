import MemorriCore
import SwiftUI

extension MarkedText {
    /// The text with the matching words in bold on a soft highlight.
    var attributed: AttributedString {
        var result = AttributedString(text)
        for range in marks {
            guard let target = Range(range, in: result) else { continue }
            result[target].inlinePresentationIntent = .stronglyEmphasized
            result[target].backgroundColor = Color.yellow.opacity(0.35)
        }
        return result
    }
}

/// The quick-search panel: a field, the results as rows, and the state in words (contracts/ui-contract.md).
struct SearchPanelView: View {
    let model: SearchViewModel
    let onOpen: (SearchPanelModel.Target) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var customOpen = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search items and captures", text: $model.text)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { if let target = model.target() { onOpen(target) } }
                    .accessibilityLabel("Search")
            }
            .padding(12)
            filterBar
            Divider()
            resultList
        }
        .frame(width: 640, height: 420)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onChange(of: model.focusToken) { focused = true }
        .task { focused = true }
    }

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Menu("Kind") {
                ForEach([(SearchQuery.Kinds.appointments, "Appointments"), (.tasks, "Tasks"), (.reminders, "Reminders"), (.captures, "Captures")], id: \.1) { kind, name in
                    Button { model.toggle(kind) } label: { if model.kinds.contains(kind) { Label(name, systemImage: "checkmark") } else { Text(name) } }
                }
                Divider()
                Button("Any kind") { model.kinds = [] }
            }
            .accessibilityLabel("Kind filter")
            Menu("Context") {
                Button("Any context") { model.context = .any }
                Button("No context") { model.context = .none }
                Divider()
                ForEach(model.contexts, id: \.id) { context in Button(context.name) { model.context = .one(context.id) } }
            }
            .accessibilityLabel("Context filter")
            Menu("Date") {
                Button("Any date") { model.dates = nil }
                Divider()
                ForEach(SearchPanelModel.DatePreset.allCases, id: \.self) { preset in Button(preset.rawValue) { model.dates = preset.range(now: Date()) } }
                Divider()
                Button("Custom range…") { customOpen = true }
            }
            .accessibilityLabel("Date filter")
            .popover(isPresented: $customOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                    HStack { Spacer(); Button("Apply") { model.dates = SearchPanelModel.customRange(from: customFrom, to: customTo); customOpen = false }.keyboardShortcut(.defaultAction) }
                }
                .padding(12).frame(width: 240)
            }
            Toggle("Dismissed", isOn: $model.includeDismissed).toggleStyle(.checkbox)
                .accessibilityLabel("Include dismissed items")
            Spacer(minLength: 0)
            if model.hasFilters {
                Text(model.activeFilterTexts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Clear filters") { model.clearFilters() }.controlSize(.small)
                    .accessibilityLabel("Clear all filters")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    @ViewBuilder private var resultList: some View {
        if let message = model.message {
            Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(message)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.results.items.isEmpty { sectionTitle("Items") }
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            if case .capture = row, index == model.rows.firstIndex(where: { if case .capture = $0 { true } else { false } }) { sectionTitle("Captures") }
                            rowView(row, selected: model.selection == index).id(index)
                                .onTapGesture { model.selection = index; if let target = SearchPanelModel.target(rows: model.rows, selection: index) { onOpen(target) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.selection) { _, selection in if let selection { proxy.scrollTo(selection) } }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func rowView(_ row: SearchPanelModel.Row, selected: Bool) -> some View {
        Group {
            switch row {
            case .item(let id):
                if let hit = model.results.items.first(where: { $0.id == id }) { itemRow(hit) }
            case .capture(let id):
                if let hit = model.results.captures.first(where: { $0.id == id }) { captureRow(hit) }
            case .showMoreItems:
                Text("Show more items").foregroundStyle(Color.accentColor).padding(.vertical, 6)
            case .showMoreCaptures:
                Text("Show more captures").foregroundStyle(Color.accentColor).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private func itemRow(_ hit: ItemHit) -> some View {
        let contextName = model.contextName(hit.contextID)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(hit.kind)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title.attributed).lineLimit(1)
                Text(detail(hit, contextName: contextName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let snippet = hit.snippet { Text(snippet.attributed).font(.caption).lineLimit(2) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SearchPanelModel.rowText(hit, contextName: contextName))
    }

    private func captureRow(_ hit: CaptureHit) -> some View {
        let window = SearchPanelModel.windowText(app: hit.windowApp, title: hit.windowTitle)
        let header = [SearchPanelModel.dateText(hit.capturedAt), hit.displayName, window].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "camera.viewfinder").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(header).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(hit.lines, id: \.number) { line in Text(line.text.attributed).font(.callout).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SearchPanelModel.rowText(hit))
    }

    private func detail(_ hit: ItemHit, contextName: String?) -> String {
        var parts: [String] = []
        if let date = hit.date { parts.append(SearchPanelModel.dateText(date)) }
        if let contextName { parts.append(contextName) }
        if hit.status == .dismissed { parts.append("Dismissed") }
        if hit.needsReview { parts.append("Needs review") }
        if hit.matchedIn != .title { parts.append("in \(hit.matchedIn.rawValue)") }
        return parts.joined(separator: " · ")
    }

    private func symbol(_ kind: FindingKind) -> String {
        switch kind {
        case .appointment: "calendar"
        case .task: "checkmark.circle"
        case .reminder: "bell"
        case .deadline: "flag"
        }
    }
}
