import MemorriCore
import SwiftUI

/// One item: its title, the fields with where each value came from, its sightings, other titles, possible duplicates and history.
struct ItemDetailView: View {
    let model: ItemsViewModel
    let detail: ItemDetail
    @State private var titleDraft: String
    @State private var checked: Set<String> = []

    init(model: ItemsViewModel, detail: ItemDetail) {
        self.model = model
        self.detail = detail
        _titleDraft = State(initialValue: detail.item.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                fields
                sightings
                if !detail.aliases.isEmpty { aliases }
                if !detail.possibleDuplicates.isEmpty { possibleDuplicates }
                history
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.roundedBorder).font(.title3)
                .onSubmit { Task { await model.editTitle(titleDraft) } }
                .accessibilityLabel("Title. Press Return to save.")
            Text("\(detail.item.kind.rawValue.capitalized) · \(ItemListModel.dateText(detail.item)) · \(model.contextName(detail.item.contextID) ?? "No context") · \(detail.item.status.rawValue.capitalized)")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fields").font(.headline)
            ForEach(detail.fields, id: \.field) { field in
                let text = ItemListModel.fieldText(field, timezone: detail.item.timezone)
                HStack(alignment: .firstTextBaseline) {
                    Text(field.field.rawValue.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(text.value).textSelection(.enabled)
                    Spacer()
                    if let source = text.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                    if field.locked {
                        Button { Task { await model.unlock(field.field) } } label: { Image(systemName: "lock.fill") }
                            .buttonStyle(.borderless)
                            .help("Unlock: let new sightings change this value")
                            .accessibilityLabel("Unlock \(field.field.rawValue)")
                    }
                }
            }
        }
    }

    // MARK: Sightings

    private var sightings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sightings").font(.headline)
            ForEach(detail.sightings, id: \.id) { sighting in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { checked.contains(sighting.id) },
                                             set: { if $0 { checked.insert(sighting.id) } else { checked.remove(sighting.id) } }))
                        .labelsHidden()
                        .accessibilityLabel("Select the sighting from \(sighting.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sighting.capturedAt.formatted(date: .abbreviated, time: .shortened))\(sighting.displayName.map { " · \($0)" } ?? "")")
                        Text("\(sighting.title) · confidence \(String(format: "%.2f", sighting.confidence))")
                            .font(.callout).foregroundStyle(.secondary)
                        let why = ItemListModel.whyText(decisionJSON: sighting.decisionJSON)
                        if !why.isEmpty { Text("why: \(why)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Button("Split into new item") {
                let chosen = Array(checked)
                checked = []
                Task { await model.split(chosen) }
            }
            .disabled(!ItemListModel.canSplit(checked: checked, of: detail.sightings))
            .accessibilityLabel("Split the checked sightings into a new item")
        }
    }

    private var aliases: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other titles").font(.headline)
            ForEach(detail.aliases, id: \.self) { Text($0) }
        }
    }

    private var possibleDuplicates: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Possible duplicates").font(.headline)
            ForEach(detail.possibleDuplicates, id: \.self) { other in
                HStack {
                    Text(model.title(of: other))
                    Spacer()
                    Button("Merge") { Task { await model.mergeDuplicate(other) } }
                        .accessibilityLabel("Merge with \(model.title(of: other))")
                    Button("Different") { Task { await model.markDifferent(other) } }
                        .accessibilityLabel("Mark \(model.title(of: other)) as a different item")
                }
            }
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.headline)
            if detail.operations.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(detail.operations, id: \.id) { operation in
                HStack {
                    Text("\(ItemListModel.operationText(operation.kind))\(operation.byUser ? "" : " (automatic)")")
                        .strikethrough(operation.undone)
                    Text(operation.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { Task { await model.undo(operation.id) } }
                        .disabled(operation.undone)
                        .accessibilityLabel("Undo \(ItemListModel.operationText(operation.kind))")
                }
            }
        }
    }
}
