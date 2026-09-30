import MemorriCore
import SwiftUI

/// Settings → Analysis (contracts/ui-contract.md): whether new captures are analysed, the stored captures that were not,
/// and the newest pictures with what was found in them.
struct AnalysisSettingsView: View {
    let environment: AppEnvironment

    @State private var automatic = true
    @State private var unanalysed = 0
    @State private var recent: [RecentCapture] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                automaticSection
                Divider()
                storedSection
                Divider()
                recentSection
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
            ForEach(recent) { row in CaptureRow(row: row, environment: environment, onChange: reload) }
        }
    }
}

private struct CaptureRow: View {
    let row: RecentCapture
    let environment: AppEnvironment
    let onChange: () -> Void
    @State private var showFindings = false

    private var stateText: String {
        switch row.state {
        case .waiting: "Waiting"
        case .analysing: "Analysing…"
        case .analysed: "Analysed"
        case .failed(let reason): "Failed: \(reason)"
        case .notAnalysed: "Not analysed"
        }
    }

    private var contextText: String {
        guard let name = row.contextName else { return "Unassigned" }
        return row.contextChosenByUser ? "\(name) (chosen by you)" : name
    }

    /// The tags worth showing as small labels.
    private var tagLabels: [String] {
        ["application", "platform_look", "remote_session", "clock_style", "language", "theme"]
            .compactMap { key in row.tags.first { $0.key == key }?.value }
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
                Text(contextText).foregroundStyle(.secondary)
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
