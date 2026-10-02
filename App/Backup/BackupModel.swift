import AppKit
import Foundation
import MemorriCore
import Observation
import UniformTypeIdentifiers

/// The backup pieces the app holds (spec 010).
struct LibraryServices: Sendable {
    let exporter: ItemExporter
    let backup: LibraryBackup
    let restore: LibraryRestore
    let safetyCopies: SafetyCopies
}

/// What Settings > Storage shows and does for export, backup, restore and safety copies.
@MainActor @Observable
final class BackupModel {
    struct Pending: Identifiable { let id = UUID(); let package: URL; let manifest: BackupManifest }

    private let services: LibraryServices
    private var task: Task<Void, Never>?

    private(set) var sizes: LibraryBackup.Sizes?
    private(set) var progress: Double?
    private(set) var checking = false
    private(set) var safetyCopies: [SafetyCopy] = []
    private(set) var stagedManifest: BackupManifest?
    var message: String?
    var includePictures = true
    var showingBackupSheet = false
    var pending: Pending?

    init(services: LibraryServices) { self.services = services }

    func reload() {
        stagedManifest = services.restore.staged
        safetyCopies = services.safetyCopies.list()
        let backup = services.backup
        Task { sizes = await Task.detached { backup.sizes() }.value }
    }

    // MARK: Export

    func exportItems() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Memorri items.json"
        panel.message = "The items go to one file, without pictures. The file is not encrypted."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = nil
        let exporter = services.exporter
        Task {
            do {
                let count = try await Task.detached { try exporter.export(to: url) }.value
                message = "Exported \(count) \(count == 1 ? "item" : "items") to \(url.lastPathComponent)."
            } catch { message = "The items could not be exported: \(error.localizedDescription)" }
        }
    }

    // MARK: Backup

    func startBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose where the backup goes. It is not encrypted: keep it somewhere safe."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        message = nil
        progress = 0
        let backup = services.backup, pictures = includePictures
        task = Task {
            do {
                let result = try await backup.make(into: folder, includePictures: pictures) { value in Task { @MainActor [weak self] in self?.progress = value } }
                message = "Backup made: \(result.package.lastPathComponent)."
            } catch let error as BackupError { message = error.message } catch { message = "The backup could not be made." }
            progress = nil
            showingBackupSheet = false
            reload()
        }
    }

    func cancelBackup() { task?.cancel() }

    // MARK: Restore

    func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose Backup"
        panel.message = "Choose a Memorri backup (a .memorribackup folder)."
        guard panel.runModal() == .OK, let package = panel.url else { return }
        message = nil
        checking = true
        let restore = services.restore
        Task {
            defer { checking = false }
            do {
                let manifest = try await Task.detached { try restore.validate(package) }.value
                pending = Pending(package: package, manifest: manifest)
            } catch let error as BackupError { message = error.message } catch { message = "The backup could not be checked." }
        }
    }

    /// Stages the checked backup and restarts the app, which finishes the restore before it opens the library.
    func confirmRestore(_ chosen: Pending) {
        pending = nil
        let restore = services.restore
        Task {
            do {
                _ = try await Task.detached { try restore.stage(chosen.package) }.value
                Self.relaunch()
            } catch let error as BackupError { message = error.message } catch { message = "The restore could not be prepared." }
        }
    }

    func cancelStagedRestore() {
        try? services.restore.cancelStaged()
        reload()
    }

    func restartNow() { Self.relaunch() }

    func deleteSafetyCopy(_ name: String) {
        try? services.safetyCopies.delete(name)
        reload()
    }

    private static func relaunch() {
        let path = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open '\(path)'"]
        try? process.run()
        NSApp.terminate(nil)
    }
}
