import AppKit
import MemorriCore

/// The one-time messages about the capture database (contracts/ui-contract.md).
@MainActor
enum StartupAlerts {
    static func showIfNeeded(for storage: StorageContext) {
        let text: String
        if case .damagedDatabaseSetAside(let name)? = storage.notice {
            text = "Memorri could not read its capture database and started a new one. The old file was kept as \(name) in the Memorri folder."
        } else if storage.capturingDisabledReason != nil {
            text = "This capture database was created by a newer version of Memorri and was left untouched. Update Memorri to use it."
        } else {
            return
        }
        // After launch has finished, so the alert has a running app to appear in.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Capture database"
            alert.informativeText = text
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
