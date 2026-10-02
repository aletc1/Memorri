import AppKit
import MemorriCore
import SwiftUI

/// Settings → Storage (contracts/ui-contract.md): what captures use, and clean-up.
struct StorageSettingsView: View {
    let environment: AppEnvironment

    @State private var summary: StorageSummary?
    @State private var daysText = "30"
    @State private var message: String?
    @State private var keepForever = false
    @State private var keepDaysText = "7"
    @State private var sizeText = "2048"
    @State private var sizeMessage: String?
    @State private var isBusy = false

    private static let keptNote = "Appointments, tasks and reminders found in them are kept."

    var body: some View {
        ScrollView {
            content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { loadSettings(); refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if environment.storageServices == nil {
                Text("The capture storage could not be opened.").foregroundStyle(.secondary)
            } else {
                summarySection
                Divider()
                retentionSection
                Divider()
                analysisSizeSection
                Divider()
                cleanUpSection
                Divider()
                BackupSection(environment: environment)
            }
        }
    }

    // MARK: Retention (spec 002, user story 5)

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Retention").font(.headline)
            HStack {
                Picker("Keep captures", selection: $keepForever) {
                    Text("Forever").tag(true)
                    Text("For").tag(false)
                }
                .fixedSize()
                if !keepForever {
                    TextField("days", text: $keepDaysText)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("days")
                }
                Button("Apply") { applyRetention() }
            }
            Text("Captures are the raw screenshots. Appointments, tasks and reminders found in them are always kept.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retentionMessage {
                Text(retentionMessage).font(.callout).foregroundStyle(.red)
            }
        }
    }

    @State private var retentionMessage: String?

    private func applyRetention() {
        guard let services = environment.storageServices else { return }
        retentionMessage = nil
        let policy: RetentionPolicy
        if keepForever {
            policy = .forever
        } else if let days = Int(keepDaysText.trimmingCharacters(in: .whitespaces)),
                  StorageSettings.retentionDaysRange.contains(days) {
            policy = .days(days)
        } else {
            retentionMessage = "Enter a whole number of days between 1 and 3650."
            return
        }
        let current = services.settings.retention
        guard policy != current else { return }
        Task {
            if policy.isShorter(than: current) {
                let preview = await Task.detached { try? services.retention.removalPreview(for: policy, now: Date()) }.value
                if let preview, preview.captureCount > 0,
                   case .days(let days) = policy,
                   !Self.confirm("Setting the retention to \(days) days removes \(Self.captures(preview.captureCount)) now (\(Self.size(preview.bytes))). \(Self.keptNote)", confirmTitle: "Change") {
                    loadSettings()                       // cancelled: nothing changes
                    return
                }
            }
            guard services.settings.setRetention(policy) else { return }
            _ = await Task.detached { try? services.retention.runNow(now: Date()) }.value
            refresh()
        }
    }

    // MARK: Analysis copy size (spec 002, user story 6)

    private var analysisSizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis copy").font(.headline)
            HStack {
                Text("Longer side of the analysis copy (pixels)")
                TextField("2048", text: $sizeText)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { applySize() }
                Button("Apply") { applySize() }
            }
            Text("Applies to new captures.").font(.callout).foregroundStyle(.secondary)
            if let sizeMessage {
                Text(sizeMessage).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func applySize() {
        guard let settings = environment.storageServices?.settings else { return }
        if let value = Int(sizeText.trimmingCharacters(in: .whitespaces)), settings.setModelLongEdge(value) {
            sizeMessage = nil
        } else {
            sizeMessage = "Enter a value between 512 and 4096."
            sizeText = String(settings.modelLongEdge)    // keep the previous value
        }
    }

    private func loadSettings() {
        guard let settings = environment.storageServices?.settings else { return }
        switch settings.retention {
        case .forever: keepForever = true
        case .days(let days): keepForever = false; keepDaysText = String(days)
        }
        sizeText = String(settings.modelLongEdge)
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage").font(.headline)
            Text(summary.map { Self.captures($0.captureCount) } ?? "…")
            Text("Pictures: \(summary.map { Self.size($0.pictureBytes) } ?? "…")")
            Text("Evidence: \(summary.map { Self.size($0.evidenceBytes) } ?? "…")")
                .help("Cut-outs of the captures that show where each item's values were read. They stay while the item exists; Delete All removes them.")
            Text("Database: \(summary.map { Self.size($0.databaseBytes) } ?? "…")")
            if let safety = summary?.safetyCopyBytes, safety > 0 { Text("Safety copies and a waiting restore: \(Self.size(safety))") }
        }
    }

    // MARK: Clean up

    private var cleanUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean up").font(.headline)
            HStack {
                Text("Delete captures older than")
                TextField("days", text: $daysText)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("days")
                Button("Delete…") { deleteOlderThanDays() }
                    .disabled(isBusy)
            }
            Button("Delete all captures…") { deleteAll() }
                .disabled(isBusy)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func deleteOlderThanDays() {
        guard let days = Int(daysText.trimmingCharacters(in: .whitespaces)),
              StorageSettings.retentionDaysRange.contains(days) else {
            message = "Enter a whole number of days between 1 and 3650."
            return
        }
        confirmAndDelete(days: days) { preview in
            "Delete \(Self.captures(preview.captureCount)) older than \(days) days? This frees \(Self.size(preview.bytes)) and cannot be undone. \(Self.keptNote)"
        } confirmTitle: { "Delete" }
    }

    private func deleteAll() {
        confirmAndDelete(days: nil) { preview in
            "Delete all \(Self.captures(preview.captureCount)) and the evidence cut-outs? This frees \(Self.size(preview.bytes)) and cannot be undone. \(Self.keptNote)"
        } confirmTitle: { "Delete All" }
    }

    private func confirmAndDelete(days: Int?, question: @escaping (CleanupService.Preview) -> String,
                                  confirmTitle: () -> String) {
        guard let cleanup = environment.storageServices?.cleanup else { return }
        let title = confirmTitle()
        message = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            let preview = await Task.detached { try? cleanup.preview(olderThanDays: days) }.value
            guard let preview else { message = "Could not read the captures."; return }
            guard preview.captureCount > 0 else {
                Self.inform("No captures match.")
                return
            }
            guard Self.confirm(question(preview), confirmTitle: title) else { return }
            let removed = await Task.detached { try? cleanup.delete(olderThanDays: days) }.value
            message = removed.map { "Deleted \(Self.captures($0))." } ?? "Could not delete the captures."
            refresh()
        }
    }

    private func refresh() {
        guard let stats = environment.storageServices?.stats else { return }
        Task { summary = await Task.detached { try? stats.summary() }.value }
    }

    // MARK: Dialogs and formatting

    /// Cancel is the default button.
    private static func confirm(_ text: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: confirmTitle)
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func inform(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func captures(_ count: Int) -> String {
        count == 1 ? "1 capture" : "\(count) captures"
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
