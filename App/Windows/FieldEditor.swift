import MemorriCore
import SwiftUI

/// One row of the detail's `Fields`: the value, where it came from, its lock, and an inline editor of the right kind for the field
/// (contracts/ui-contract.md). A confirmed edit becomes the user's locked value; a rejected one shows why under the field and keeps the old one.
struct FieldRowView: View {
    let model: ItemsViewModel
    let item: Item
    let field: ItemField
    let history: FieldHistory?

    @State private var editing = false
    @State private var draft = ""
    @State private var date = Date()
    @State private var flag = false
    @State private var error: String?
    @State private var saving = false
    @State private var showValues = false

    private var name: String { field == .remind ? "reminder" : field.rawValue.replacingOccurrences(of: "_", with: " ") }
    private var isDate: Bool { [.start, .end, .due, .remind].contains(field) }
    private var canClear: Bool { [.end, .due, .remind, .place, .notes].contains(field) }
    private var current: JSONValue? { history?.current }
    private var isEmpty: Bool { current == nil || current == .null || (field == .people && (current?.asStrings ?? []).isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name.capitalized).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                if editing { editor } else { display }
            }
            if showValues, !editing, let history { values(of: history) }
        }
    }

    /// Every value seen or set for the field, with the current one marked (FR-005).
    private func values(of history: FieldHistory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ItemListModel.provenance(history, timezone: item.timezone)) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle").foregroundStyle(row.isCurrent ? Color.green : .secondary)
                        .imageScale(.small).accessibilityLabel(row.isCurrent ? "Current value" : "Earlier value")
                    Text(row.value).lineLimit(2)
                    Text([row.source, row.confidence.map { "confidence \($0)" }, row.when].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.leading, 92)
    }

    // MARK: Showing

    private var display: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isEmpty && history?.locked != true {
                Button("Add") { begin() }
                    .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Add \(name)")
            } else {
                let text = history.map { ItemListModel.fieldText($0, timezone: item.timezone) } ?? (value: "none", source: nil as String?)
                Text(text.value).textSelection(.enabled).foregroundStyle(isEmpty ? .secondary : .primary)
                    .onTapGesture(count: 2) { begin() }
                Spacer(minLength: 8)
                if let source = text.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                if let history, history.entries.count > 1 || history.locked {
                    Button { showValues.toggle() } label: { Image(systemName: showValues ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.borderless)
                        .help(showValues ? "Hide the values behind it" : "Show the values behind it")
                        .accessibilityLabel(showValues ? "Hide the values behind \(name)" : "Show the values behind \(name)")
                }
                if history?.locked == true {
                    Button { Task { await model.unlock(field) } } label: { Image(systemName: "lock.fill") }
                        .buttonStyle(.borderless)
                        .help("Unlock: let new sightings change this value")
                        .accessibilityLabel("Unlock \(name)")
                }
                Button { begin() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit \(name)")
                    .accessibilityLabel("Edit \(name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
            }
            HStack(spacing: 8) {
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
                    .accessibilityLabel("Save \(name)")
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel editing \(name)")
                if canClear {
                    Button("Clear") { clear() }.disabled(saving)
                        .help("Leave \(name) empty and keep it that way")
                        .accessibilityLabel("Clear \(name)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand { cancel() }
    }

    @ViewBuilder
    private var control: some View {
        if isDate {
            DatePicker(name, selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().environment(\.timeZone, TimeZone(identifier: item.timezone) ?? .gmt)
                .accessibilityLabel("\(name.capitalized), in the item's time zone")
        } else if field == .allDay {
            Toggle("All day", isOn: $flag).accessibilityLabel("All day")
        } else if field == .notes {
            TextEditor(text: $draft)
                .font(.body).frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                .accessibilityLabel("Notes")
        } else {
            TextField(name.capitalized, text: $draft, prompt: Text(field == .people ? "Names separated by commas" : ""))
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityLabel(field == .people ? "People, names separated by commas" : name.capitalized)
        }
    }

    private func begin() {
        error = nil
        draft = ItemListModel.editText(current, field: field, timezone: item.timezone)
        if isDate { date = current?.asDate ?? item.start ?? item.due ?? Date() }
        if field == .allDay { flag = current?.asBool ?? false }
        editing = true
    }

    private func cancel() { editing = false; error = nil }

    private func clear() { submit(field == .people ? .array([]) : .null) }

    private func save() {
        if isDate { submit(.date(date)); return }
        if field == .allDay { submit(.bool(flag)); return }
        switch ItemListModel.parse(draft, field: field, timezone: item.timezone) {
        case .success(let value): submit(value)
        case .failure(let failure): error = failure.message
        }
    }

    private func submit(_ value: JSONValue) {
        saving = true
        Task {
            let message = await model.edit(field: field, value: value)
            saving = false
            error = message
            if message == nil { editing = false }
        }
    }
}
