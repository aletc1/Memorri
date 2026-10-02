import MemorriCore
import SwiftUI

/// The Items window (contracts/ui-contract.md): the list of items with filters on the left, the open item on the right.
struct ItemsView: View {
    @State private var model: ItemsViewModel
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: ItemsViewModel(environment: environment))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar(model: model)
            Divider()
            if !model.isAvailable {
                Text("The capture storage is not available, so there are no items to show.")
                    .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Group {
                        if model.viewMode == .calendar { CalendarMonthView(model: model) } else { list(model: model) }
                    }
                    .frame(minWidth: model.viewMode == .calendar ? 480 : 340, idealWidth: model.viewMode == .calendar ? 560 : 400)
                    detailPane.frame(minWidth: 340)
                }
            }
            if let message = model.message {
                Divider()
                Text(message).foregroundStyle(.red).font(.callout).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .onAppear { model.start(); open(environment.state.itemsScopeRequest) }
        .onChange(of: environment.state.itemsScopeRequest) { _, request in open(request) }
        .onChange(of: model.selection) { model.selectionChanged() }
        .sheet(item: $model.lockSheet) { sheet in
            LockChoiceSheet(sheet: sheet,
                            onCancel: { model.lockSheet = nil },
                            onMerge: { picked in Task { await model.resolveLockSheet(sheet, picked: picked) } })
        }
    }

    /// The menu's `Inbox` opens this window on the Inbox scope.
    private func open(_ request: AppState.ScopeRequest?) {
        guard let request else { return }
        if let id = request.itemID {
            model.filter = ItemListModel.filter(showing: request.status ?? .active)
            model.select(id)
        } else {
            model.filter.scope = request.scope
        }
    }

    // MARK: Header (one row, spec 012)

    private func toolbar(model: ItemsViewModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "list.bullet").tag(ItemsViewModel.ViewMode.list).help("List")
                Image(systemName: "calendar").tag(ItemsViewModel.ViewMode.calendar).help("Calendar")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel("List or calendar view")

            Picker("Show", selection: $model.filter.scope) {
                Text("Items").tag(ItemScope.all)
                Text("Inbox (\(model.inboxCount))").tag(ItemScope.inbox)
                Text("Approved").tag(ItemScope.approved)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Show items, the Inbox or approved items")

            Picker("Kind", selection: $model.filter.kind) {
                Text("All kinds").tag(ItemKindFilter.all)
                Text("Appointments").tag(ItemKindFilter.appointments)
                Text("Tasks").tag(ItemKindFilter.tasks)
                Text("Reminders").tag(ItemKindFilter.reminders)
            }
            .labelsHidden().fixedSize()
            .help("Tasks include deadlines")
            .accessibilityLabel("Kind filter")

            Picker("Context", selection: $model.filter.context) {
                Text("All contexts").tag(ItemContextFilter.all)
                ForEach(model.contexts, id: \.id) { Text($0.name).tag(ItemContextFilter.context($0.id)) }
                Text("No context").tag(ItemContextFilter.none)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Context filter")

            Toggle(isOn: $model.filter.showDismissed) { Image(systemName: "eye.slash") }
                .toggleStyle(.button)
                .help(model.filter.showDismissed ? "Hide dismissed items" : "Show dismissed items")
                .accessibilityLabel("Show dismissed items")

            TextField("Search items", text: $model.searchText)
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, idealWidth: 180, maxWidth: 220)
                .accessibilityLabel("Search items")

            Spacer(minLength: 0)

            if model.canApprove {
                iconButton("checkmark", "Approve", "Approve the selected items") { await model.approve() }
            }
            if model.canMerge {
                iconButton("arrow.triangle.merge", "Merge", "Merge the two selected items") { await model.merge() }
            }
            if let action = model.statusAction {
                iconButton(action == .dismiss ? "xmark" : "arrow.uturn.backward.circle",
                           action == .dismiss ? "Dismiss" : "Restore",
                           action == .dismiss ? "Dismiss the selected items" : "Restore the selected items") { await model.dismissOrRestore() }
            }
            Button { Task { await model.undoLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(model.undoTarget == nil)
                .help(model.undoTarget.map { "Undo: \(ItemListModel.operationText($0.kind))" } ?? "Nothing to undo")
                .accessibilityLabel("Undo your last operation")
        }
        .padding(10)
    }

    private func iconButton(_ symbol: String, _ help: String, _ label: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .help(help).accessibilityLabel(label)
    }

    // MARK: List

    @ViewBuilder
    private func list(model: ItemsViewModel) -> some View {
        @Bindable var model = model
        if model.rows.isEmpty {
            Text(ItemListModel.emptyText(scope: .all))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleRows.isEmpty {
            Text(model.filter.scope == .all ? "No items match the filters." : ItemListModel.emptyText(scope: model.filter.scope))
                .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $model.selection) {
                ForEach(model.visibleRows, id: \.item.id) { row in
                    ItemRowView(row: row, text: ItemListModel.rowText(row, contextName: model.contextName(row.item.contextID)))
                        .tag(row.item.id)
                }
            }
            .onKeyPress(.return) {
                guard model.filter.scope == .inbox, model.canApprove else { return .ignored }
                Task { await model.approve() }
                return .handled
            }
            .onDeleteCommand {
                guard model.filter.scope == .inbox, model.statusAction == .dismiss else { return }
                Task { await model.dismissOrRestore() }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.selection.count > 1 {
            Text("\(model.selection.count) items selected").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = model.detail, model.selection.count == 1 {
            ItemDetailView(model: model, detail: detail).id(detail.item.id)
        } else {
            Text("Select an item.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ItemRowView: View {
    let row: ItemRow
    let text: ItemRowText

    private var symbol: String {
        switch row.item.kind {
        case .appointment: "calendar"
        case .task: "checklist"
        case .reminder: "bell"
        case .deadline: "flag"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).fontWeight(.medium).lineLimit(2)
                Text(text.when).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(text.context)
                    Text(text.sightings)
                    if text.locked {
                        Image(systemName: "lock.fill").accessibilityLabel("Has a value you set")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !text.reasons.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small).accessibilityLabel(text.approval)
                        ForEach(text.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        }
        .opacity(text.dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// `Both items have your value for <field>. Keep:` with the two values; Cancel aborts the merge.
private struct LockChoiceSheet: View {
    let sheet: ItemsViewModel.LockSheet
    let onCancel: () -> Void
    let onMerge: ([ItemField: String]) -> Void
    @State private var picked: [ItemField: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sheet.choices) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(choice.prompt).font(.headline)
                    Picker(choice.prompt, selection: Binding(get: { picked[choice.field] ?? choice.keepItem },
                                                            set: { picked[choice.field] = $0 })) {
                        Text(choice.keepValue).tag(choice.keepItem)
                        Text(choice.otherValue).tag(choice.otherItem)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    var all = picked
                    for choice in sheet.choices where all[choice.field] == nil { all[choice.field] = choice.keepItem }
                    onMerge(all)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 380)
    }
}
