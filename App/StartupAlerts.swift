import AppKit
import MemorriCore

/// The one-time messages about the capture database (contracts/ui-contract.md).
@MainActor
enum StartupAlerts {
    /// What a restore finished at this start did, told once (spec 010).
    static func showRestoreResult(paths: AppPaths) {
        guard let result = StorageBootstrap.takeRestoreResult(paths: paths) else { return }
        let text: String
        switch result.outcome {
        case .restored:
            text = "Your library was restored from the backup" + (result.backupCreated.map { " made \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                + ". The library it replaced is kept as a safety copy in Settings > Storage until you delete it."
                + (result.includesPictures == false ? " The backup had no capture pictures, so those captures cannot be read again." : "")
                + " Calendar sync will show a preview before it writes anything."
        case .failed:
            text = "The restore could not be finished (\(result.reason ?? "unknown reason")). Your library was left as it was."
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = result.outcome == .restored ? "Backup restored" : "Restore not finished"
            alert.informativeText = text
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

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
