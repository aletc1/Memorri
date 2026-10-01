import MemorriCore
import SwiftUI

/// Settings → Analysis (contracts/ui-contract.md): whether new captures are analysed, the stored captures that were not,
/// and the newest pictures with what was found in them.
struct AnalysisSettingsView: View {
    let environment: AppEnvironment

    @State private var automatic = true
    @State private var unanalysed = 0
    @State private var recent: [RecentCapture] = []
    @State private var contexts: [ContextRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                automaticSection
                Divider()
                storedSection
                Divider()
                recentSection
                Divider()
                ContextsBlock(environment: environment, onChange: reload)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            automatic = environment.analysisSettings.automatic
            reload()
        }
        .onChange(of: environment.state.analysisProgress) { reload() }
    }

    private func reload() {
        unanalysed = environment.unanalysedCount()
        recent = (try? environment.captureOverview?.recent(limit: 20)) ?? []
        contexts = (try? environment.contexts?.all()) ?? []
    }

    // MARK: Automatic analysis

    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Analyse new captures automatically", isOn: $automatic)
                .onChange(of: automatic) { _, value in environment.analysisSettings.setAutomatic(value) }
            Text("Turn it off to capture without analysing. Pause analysis in the menu stops work without changing this.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stored captures

    private var storedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stored captures").font(.headline)
            HStack {
                Button("Analyse stored captures") {
                    Task { await environment.analyseStoredCaptures(); reload() }
                }
                .disabled(unanalysed == 0)
                Text("\(unanalysed) \(unanalysed == 1 ? "capture has" : "captures have") not been analysed.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Recent captures

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent captures").font(.headline)
            if recent.isEmpty {
                Text("No captures yet.").foregroundStyle(.secondary)
            }
            ForEach(recent) { row in CaptureRow(row: row, contexts: contexts, environment: environment, onChange: reload) }
        }
    }
}

private struct CaptureRow: View {
    let row: RecentCapture
    let contexts: [ContextRecord]
    let environment: AppEnvironment
    let onChange: () -> Void
    @State private var showFindings = false
    @State private var choice: String?

    init(row: RecentCapture, contexts: [ContextRecord], environment: AppEnvironment, onChange: @escaping () -> Void) {
        self.row = row; self.contexts = contexts; self.environment = environment; self.onChange = onChange
        _choice = State(initialValue: row.contextID)
    }

    private var stateText: String {
        switch row.state {
        case .waiting: "Waiting"
        case .analysing: "Analysing…"
        case .analysed: "Analysed"
        case .failed(let reason): "Failed: \(reason)"
        case .notAnalysed: "Not analysed"
        }
    }

    /// The tags worth showing as small labels.
    private var tagLabels: [String] {
        ["application", "platform_look", "remote_session", "clock_style", "language", "theme"]
            .compactMap { key in row.tags.first { $0.key == key }?.value }
    }

    /// Who the picture seems to belong to: shown only inside the findings, never in the list row.
    private var accountLine: String? {
        let accounts = row.tags.filter { $0.key == "account" }.map(\.value), domains = row.tags.filter { $0.key == "domain" }.map(\.value)
        let parts = [accounts.isEmpty ? nil : "Account: " + accounts.joined(separator: ", "),
                     domains.isEmpty ? nil : "Domain: " + domains.joined(separator: ", ")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.capturedAt.formatted(date: .abbreviated, time: .standard)).font(.body.weight(.medium))
                Text("\(row.displayCount) \(row.displayCount == 1 ? "display" : "displays")").foregroundStyle(.secondary)
                Spacer()
                Button("Reanalyse") { Task { await environment.reanalyse(imageID: row.id); onChange() } }
                    .disabled(row.state == .waiting || row.state == .analysing)
            }
            HStack(spacing: 8) {
                Text(stateText).foregroundStyle(stateColor)
                if let kind = row.kind { Text(kind.displayName) }
                Picker("Context", selection: $choice) {
                    Text("Unassigned").tag(String?.none)
                    ForEach(contexts) { Text($0.name).tag(String?.some($0.id)) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: choice) { _, value in
                    guard value != row.contextID else { return }
                    Task { await environment.changeContext(imageID: row.id, to: value); onChange() }
                }
                .onChange(of: row.contextID) { _, value in choice = value }
                if row.contextChosenByUser { Text("(chosen by you)").foregroundStyle(.secondary) }
                Text("\(row.findingCount) \(row.findingCount == 1 ? "finding" : "findings")").foregroundStyle(.secondary)
            }
            .font(.callout)
            if !tagLabels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tagLabels, id: \.self) { label in
                        Text(label).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            if !row.findings.isEmpty {
                DisclosureGroup("Findings", isExpanded: $showFindings) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(row.findings, id: \.id) { Text(FindingLine.text(for: $0)).font(.callout).textSelection(.enabled) }
                        if let accountLine { Text(accountLine).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private var stateColor: Color {
        if case .failed = row.state { return .red }
        return .primary
    }
}

// MARK: Contexts

/// The user's contexts: a name, the time zone its pictures' dates are read in, and the hints that recognise its pictures.
private struct ContextsBlock: View {
    let environment: AppEnvironment
    let onChange: () -> Void
    @State private var contexts: [ContextRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contexts").font(.headline)
            Text("A context is a customer, a remote session or a workspace. Memorri gives a picture to a context when it finds one of the context's hints in it, "
                 + "and reads the picture's dates in that context's time zone. Window title and application hints count the most. "
                 + "Choose Reanalyse on a picture after changing a context.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if contexts.isEmpty { Text("No contexts yet.").foregroundStyle(.secondary) }
            ForEach(contexts) { context in
                ContextEditor(context: context, store: environment.contexts, onChange: { reload(); onChange() }).id(context.id)
            }
            Button { add() } label: { Label("Add context", systemImage: "plus") }.disabled(environment.contexts == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
    }

    private func reload() { contexts = (try? environment.contexts?.all()) ?? [] }

    private func add() {
        guard let store = environment.contexts else { return }
        var number = 1
        while true {
            let name = number == 1 ? "New context" : "New context \(number)"
            do { try store.add(name: name, timezone: nil, hints: []); break }
            catch ContextError.nameInUse { number += 1 }
            catch { return }
        }
        reload(); onChange()
    }
}

private struct ContextEditor: View {
    private struct HintDraft: Identifiable { let id = UUID(); var kind: ContextHint.Kind; var value: String }

    let context: ContextRecord
    let store: ContextStore?
    let onChange: () -> Void
    @State private var name: String
    @State private var timezone: String?
    @State private var hints: [HintDraft]
    @State private var message: String?
    @FocusState private var focused: String?

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    init(context: ContextRecord, store: ContextStore?, onChange: @escaping () -> Void) {
        self.context = context; self.store = store; self.onChange = onChange
        _name = State(initialValue: context.name)
        _timezone = State(initialValue: context.timezone)
        _hints = State(initialValue: context.hints.map { HintDraft(kind: $0.kind, value: $0.value) })
    }

    private func label(_ kind: ContextHint.Kind) -> String {
        switch kind {
        case .windowTitle: "Window title contains"
        case .app: "Application is"
        case .domain: "Web or mail domain"
        case .keyword: "Text on screen contains"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Customer or workspace name", text: $name).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: "name").onSubmit(save)
                    Button(role: .destructive) { try? store?.delete(id: context.id); onChange() } label: { Label("Delete", systemImage: "trash") }
                }
                GridRow {
                    Text("Time zone").foregroundStyle(.secondary)
                    Picker("Time zone", selection: $timezone) {
                        Text("Mac's time zone").tag(String?.none)
                        ForEach(Self.zones, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .onChange(of: timezone) { save() }
                    .gridCellColumns(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Recognise its pictures by").font(.subheadline).foregroundStyle(.secondary)
                ForEach($hints) { $hint in
                    HStack(spacing: 8) {
                        Picker("Hint", selection: $hint.kind) {
                            ForEach(ContextHint.Kind.allCases, id: \.self) { Text(label($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 190)
                        .onChange(of: hint.kind) { save() }
                        TextField("Text to look for", text: $hint.value).textFieldStyle(.roundedBorder)
                            .focused($focused, equals: hint.id.uuidString).onSubmit(save)
                        Button { hints.removeAll { $0.id == hint.id }; save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this hint")
                    }
                }
                Button { hints.append(HintDraft(kind: .windowTitle, value: "")) } label: { Label("Add hint", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        .onChange(of: focused) { old, new in if old != nil, old != new { save() } }
    }

    private func save() {
        guard let store else { return }
        var record = context
        record.name = name
        record.timezone = timezone
        record.hints = hints.map { ContextHint(kind: $0.kind, value: $0.value) }
        do {
            try store.update(record)
            message = nil
            onChange()
        } catch let error as ContextError {
            message = error.description
        } catch {
            message = "Could not save."
        }
    }
}
