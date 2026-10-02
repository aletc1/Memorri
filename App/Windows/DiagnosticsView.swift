import AppKit
import MemorriCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Diagnostics (spec 010, contracts/ui-contract.md 4): figures and sanitised log lines, saved as a plain file the user can share. No item text.
struct DiagnosticsView: View {
    let environment: AppEnvironment
    @State private var report: DiagnosticsReport?
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title2).bold()
            Text("What Memorri is doing: versions, permissions, the queue, sync, storage and its own recent log lines. It never holds item titles, places, people, notes, text read from the screen, model answers, window titles or pictures, so you can share it with whoever helps. Nothing is sent anywhere.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { Task { await load() } }.disabled(loading)
                Button("Save report…") { save(json: false) }.disabled(report == nil)
                    .help("Writes this report as a text file in a place you choose")
                Button("Save as JSON…") { save(json: true) }.disabled(report == nil)
                if loading { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.callout) }
            ScrollView {
                Text(report?.text ?? (loading ? "Gathering…" : "The library is not available, so there is nothing to report."))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(24)
        .task { await load() }
    }

    private func load() async {
        loading = true
        report = await DiagnosticsSource(environment: environment).report()
        loading = false
    }

    private func save(json: Bool) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [json ? .json : .plainText]
        panel.nameFieldStringValue = json ? "Memorri diagnostics.json" : "Memorri diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (json ? report.json : report.text).write(to: url, atomically: true, encoding: .utf8); message = "Saved \(url.lastPathComponent)." }
        catch { message = "The report could not be saved: \(error.localizedDescription)" }
    }
}
