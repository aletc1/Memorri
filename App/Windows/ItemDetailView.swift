import MemorriCore
import SwiftUI

/// One item: its title, the fields with where each value came from, its sightings, other titles, possible duplicates and history.
struct ItemDetailView: View {
    let model: ItemsViewModel
    let detail: ItemDetail
    @State private var checked: Set<String> = []
    @State private var showAll = false
    @State private var wholeCapture: EvidenceEntry?

    init(model: ItemsViewModel, detail: ItemDetail) {
        self.model = model
        self.detail = detail
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                fields
                evidenceSection
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
            Text(detail.item.title).font(.title3).fontWeight(.semibold).textSelection(.enabled)
            Text("\(detail.item.kind.rawValue.capitalized) · \(ItemListModel.dateText(detail.item)) · \(model.contextName(detail.item.contextID) ?? "No context") · \(detail.item.status.rawValue.capitalized)")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if detail.item.needsReview {
                    Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small)
                    Text("Needs review").fontWeight(.medium)
                    Text(ItemListModel.reviewText(detail.item.reviewReasons).joined(separator: " · ")).foregroundStyle(.orange)
                    Button("Approve") { Task { await model.approve() } }
                        .accessibilityLabel("Approve this item")
                } else {
                    Text(ItemListModel.approvalText(detail.item)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields").font(.headline)
            ForEach(ItemField.allCases, id: \.self) { field in
                FieldRowView(model: model, item: detail.item, field: field, history: detail.fields.first { $0.field == field })
            }
        }
    }

    // MARK: Evidence

    private var evidenceSection: some View {
        let entries = ItemListModel.evidenceEntries(sightings: detail.sightings, evidence: model.evidence)
        let visible = ItemListModel.shownEntries(entries, showAll: showAll)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Evidence").font(.headline)
            ForEach(visible.shown) { entry in
                EvidenceCardView(entry: entry, model: model,
                                 isChecked: entry.sighting.map { sighting in
                                     Binding(get: { checked.contains(sighting.id) },
                                             set: { if $0 { checked.insert(sighting.id) } else { checked.remove(sighting.id) } })
                                 },
                                 isTitleSource: entry.sighting?.id == ItemListModel.sourceSightingID(detail.fields.first { $0.field == .title }),
                                 onShowWhole: { wholeCapture = entry })
            }
            if let more = visible.moreText {
                Button(more) { showAll = true }.buttonStyle(.link)
            }
            Button("Split into new item") {
                let chosen = Array(checked)
                checked = []
                Task { await model.split(chosen) }
            }
            .disabled(!ItemListModel.canSplit(checked: checked, of: detail.sightings))
            .accessibilityLabel("Split the checked sightings into a new item")
        }
        .sheet(item: $wholeCapture) { entry in
            WholeCaptureSheet(entry: entry, model: model, onClose: { wholeCapture = nil })
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
