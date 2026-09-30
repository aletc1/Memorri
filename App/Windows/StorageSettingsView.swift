import AppKit
import MemorriCore
import SwiftUI

/// Settings → Storage (contracts/ui-contract.md): what captures use, and clean-up.
struct StorageSettingsView: View {
    let environment: AppEnvironment

    @State private var summary: StorageSummary?
    @State private var daysText = "30"
    @State private var message: String?
    @State private var isBusy = false

    private static let keptNote = "Appointments, tasks and reminders found in them are kept."

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if environment.storageServices == nil {
                Text("The capture storage could not be opened.").foregroundStyle(.secondary)
            } else {
                summarySection
                Divider()
                cleanUpSection
            }
        }
        .padding(24)
        .onAppear { refresh() }
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage").font(.headline)
            Text(summary.map { "\($0.captureCount) captures" } ?? "…")
            Text("Pictures: \(summary.map { Self.size($0.pictureBytes) } ?? "…")")
            Text("Database: \(summary.map { Self.size($0.databaseBytes) } ?? "…")")
            Text("Captures are the raw screenshots. Appointments, tasks and reminders found in them are always kept.")
                .font(.callout).foregroundStyle(.secondary)
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
            "Delete \(preview.captureCount) captures older than \(days) days? This frees \(Self.size(preview.bytes)) and cannot be undone. \(Self.keptNote)"
        } confirmTitle: { "Delete" }
    }

    private func deleteAll() {
        confirmAndDelete(days: nil) { preview in
            "Delete all \(preview.captureCount) captures? This frees \(Self.size(preview.bytes)) and cannot be undone. \(Self.keptNote)"
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
            message = removed.map { "Deleted \($0) captures." } ?? "Could not delete the captures."
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

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
