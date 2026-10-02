import MemorriCore
import SwiftUI

/// Settings > Storage > Backup (spec 010, contracts/ui-contract.md 3): export the items, back up and restore the library, the safety copies.
struct BackupSection: View {
    let environment: AppEnvironment
    @State private var model: BackupModel?

    var body: some View {
        Group {
            if let model { content(model) }
        }
        .task {
            guard model == nil, let services = environment.library else { return }
            let created = BackupModel(services: services)
            model = created
            created.reload()
        }
    }

    @ViewBuilder
    private func content(_ model: BackupModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup").font(.headline)
            Text("Take your items or your whole library away, and bring a backup back. Files go only where you choose, and they are not encrypted: they hold your real material.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export items…") { model.exportItems() }
                    .help("Writes every item, with its fields and the text it was read from, to one JSON file. No pictures")
                Button("Back up library…") { model.showingBackupSheet = true }
                    .disabled(model.progress != nil)
                    .help("Copies the library to a folder you choose, to restore later or on another Mac")
                Button("Restore from backup…") { model.chooseBackupToRestore() }
                    .disabled(model.checking || model.stagedManifest != nil)
                    .help("Replaces the current library with a backup, after a restart. The library it replaces is kept as a safety copy")
                if model.checking { ProgressView().controlSize(.small) }
            }
            if let staged = model.stagedManifest {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("A restore from the backup of \(staged.created.formatted(date: .abbreviated, time: .shortened)) waits for the next start.")
                    Button("Restart now") { model.restartNow() }
                    Button("Cancel restore") { model.cancelStagedRestore() }
                }
                .font(.callout)
            }
            if let message = model.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if !model.safetyCopies.isEmpty {
                Text("Safety copies").font(.subheadline).bold().padding(.top, 4)
                Text("The libraries that restores replaced. Delete them when you no longer need them.").font(.callout).foregroundStyle(.secondary)
                ForEach(model.safetyCopies) { copy in
                    HStack {
                        Text("\(copy.created.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: copy.size, countStyle: .file))")
                        Spacer()
                        Button("Delete") { model.deleteSafetyCopy(copy.name) }
                            .help("Removes this copy of the replaced library for good")
                    }
                    .font(.callout)
                }
            }
        }
        .sheet(isPresented: $model.showingBackupSheet) { backupSheet(model) }
        .sheet(item: $model.pending) { pending in restoreSheet(model, pending) }
    }

    private func size(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…" }

    private func backupSheet(_ model: BackupModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Back up the library").font(.title3).bold()
            Text("Size with capture pictures: \(size(model.sizes?.withPictures))")
            Text("Size without them: \(size(model.sizes?.withoutPictures))")
            Toggle("Include capture pictures", isOn: $model.includePictures)
                .help("Without the pictures the backup is small, but captures restored from it cannot be read again or reprocessed")
                .disabled(model.progress != nil)
            Text("The backup is a folder you can copy anywhere. It is not encrypted and holds your real material.").font(.callout).foregroundStyle(.secondary)
            if let progress = model.progress {
                ProgressView(value: progress)
                Text("Working… you can keep using Memorri.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if model.progress != nil {
                    Button("Cancel backup", role: .cancel) { model.cancelBackup() }
                } else {
                    Button("Close", role: .cancel) { model.showingBackupSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Choose Folder and Back Up…") { model.startBackup() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 440)
    }

    private func restoreSheet(_ model: BackupModel, _ pending: BackupModel.Pending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore this backup?").font(.title3).bold()
            Text("Made \(pending.manifest.created.formatted(date: .abbreviated, time: .shortened)), \(pending.manifest.files.count) files.")
            Text("Memorri restarts, and the library you have now is replaced by the backup. The library it replaces is kept as a safety copy in Settings > Storage until you delete it.")
                .fixedSize(horizontal: false, vertical: true)
            if !pending.manifest.includesPictures {
                Label("This backup has no capture pictures. Captures in it cannot be read again or reprocessed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Calendar sync waits for you to see a preview before it writes anything again.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pending = nil }.keyboardShortcut(.cancelAction)
                Button("Restore and Restart") { model.confirmRestore(pending) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}
