import MemorriCore
import SwiftUI

/// The Items window (contracts/ui-contract.md): the list of items with filters on the left, the open item on the right.
struct ItemsView: View {
    @State private var model: ItemsViewModel

    init(environment: AppEnvironment) {
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
                    list(model: model).frame(minWidth: 340, idealWidth: 400)
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
        .onAppear { model.start() }
        .onChange(of: model.selection) { model.selectionChanged() }
        .sheet(item: $model.lockSheet) { sheet in
            LockChoiceSheet(sheet: sheet,
                            onCancel: { model.lockSheet = nil },
                            onMerge: { picked in Task { await model.resolveLockSheet(sheet, picked: picked) } })
        }
    }

    // MARK: Filters and buttons

    private func toolbar(model: ItemsViewModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Kind", selection: $model.filter.kind) {
                    Text("All").tag(ItemKindFilter.all)
                    Text("Appointments").tag(ItemKindFilter.appointments)
                    Text("Tasks").tag(ItemKindFilter.tasks)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Tasks include reminders and deadlines")
                .accessibilityLabel("Kind filter")

                Picker("Context", selection: $model.filter.context) {
                    Text("All contexts").tag(ItemContextFilter.all)
                    ForEach(model.contexts, id: \.id) { Text($0.name).tag(ItemContextFilter.context($0.id)) }
                    Text("No context").tag(ItemContextFilter.none)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Context filter")

                Toggle("Show dismissed", isOn: $model.filter.showDismissed)
                    .fixedSize()
                    .accessibilityLabel("Show dismissed items")

                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if model.canMerge {
                    Button("Merge") { Task { await model.merge() } }
                        .accessibilityLabel("Merge the two selected items")
                }
                if let action = model.statusAction {
                    Button(action == .dismiss ? "Dismiss" : "Restore") { Task { await model.dismissOrRestore() } }
                        .accessibilityLabel(action == .dismiss ? "Dismiss the selected items" : "Restore the selected items")
                }
                Spacer(minLength: 0)
                Button("Undo last") { Task { await model.undoLast() } }
                    .disabled(model.undoTarget == nil)
                    .help(model.undoTarget.map { "Undo: \(ItemListModel.operationText($0.kind))" } ?? "Nothing to undo")
                    .accessibilityLabel("Undo your last operation")
            }
        }
        .padding(10)
    }

    // MARK: List

    @ViewBuilder
    private func list(model: ItemsViewModel) -> some View {
        @Bindable var model = model
        if model.rows.isEmpty {
            Text("No items yet. Items appear after captures are analysed.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleRows.isEmpty {
            Text("No items match the filters.")
                .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $model.selection) {
                ForEach(model.visibleRows, id: \.item.id) { row in
                    ItemRowView(row: row, text: ItemListModel.rowText(row, contextName: model.contextName(row.item.contextID)))
                        .tag(row.item.id)
                }
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
                    if text.possibleDuplicate {
                        Label("Possible duplicate", systemImage: "square.on.square").foregroundStyle(.orange)
                    }
                    if text.locked {
                        Image(systemName: "lock.fill").accessibilityLabel("Has a value you set")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
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
