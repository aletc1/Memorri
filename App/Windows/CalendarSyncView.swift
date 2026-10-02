import MemorriCore
import SwiftUI

/// Settings > Calendar sync (spec 009, contracts/ui-contract.md).
struct CalendarSyncView: View {
    let environment: AppEnvironment
    @State private var model: CalendarSyncModel?
    @State private var confirmingOff = false

    var body: some View {
        ScrollView {
            if let model {
                content(model)
            } else {
                Text("The capture storage is not available, so there is nothing to sync.").foregroundStyle(.secondary).padding(24)
            }
        }
        .task {
            guard let services = environment.sync else { return }
            let model = CalendarSyncModel(services: services, items: environment.items)
            self.model = model
            model.reload()
            await model.follow()
        }
        .task {
            // A calendar made in Calendar shows up without pressing Refresh: when Calendar changes, and when Memorri comes to the front again.
            for await _ in NotificationCenter.default.notifications(named: EventKitStore.changed) { model?.refresh() }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { model?.refresh() }
        }
    }

    @ViewBuilder
    private func content(_ model: CalendarSyncModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendar sync").font(.title2).bold()
            Text("Memorri copies the appointments it finds into a calendar, and the tasks and reminders into a Reminders list. It writes only in the calendar and list you choose here, and never changes anything it did not make.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            accessRow(model, .event, "Calendar")
            accessRow(model, .reminder, "Reminders")
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Where Memorri writes").font(.headline)
                    Spacer()
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Look for calendars and lists you made since. They also appear on their own when you come back to Memorri")
                }
                picker("Calendar for appointments", model.calendars, selection: model.calendarID, access: model.access(.event), missing: model.calendarMissing, notice: model.calendarNotice,
                       help: "Appointments are written only here. Create a calendar named Memorri in Calendar and it is chosen for you.") { model.chooseCalendar($0) }
                picker("List for tasks and reminders", model.lists, selection: model.listID, access: model.access(.reminder), missing: model.listMissing, notice: model.listNotice,
                       help: "Tasks and reminders are written only here. Create a list named Memorri in Reminders and it is chosen for you.") { model.chooseList($0) }
                Text("Memorri works best in a calendar and a list of its own, so what it shows stays apart from your Personal and Work calendars. Memorri never creates them for you.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sync to Calendar and Reminders", isOn: Binding(get: { model.enabled }, set: { value in
                    if value { model.setEnabled(true) } else if model.removalCount > 0 { confirmingOff = true } else { model.setEnabled(false) }
                }))
                .disabled(!model.canEnable && !model.enabled)
                .help(model.canEnable ? "Items that are ready are copied automatically. The first time, you see a preview first" : "Allow access and choose a calendar or a list first")
                Text("Items up to 90 days old that are not waiting in the Inbox. An item without a date is not written as an appointment.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.statusLine).font(.callout)
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Preview…") { Task { await model.preview() } }
                        .disabled(!model.canEnable || model.running)
                        .help("Shows what a sync would create, update or remove. Nothing is written")
                    Button("Sync now") { model.syncNow() }
                        .disabled(!model.enabled || model.running)
                        .help("Copies the items that are ready now")
                    if model.running { ProgressView().controlSize(.small) }
                }
            }
            Divider()
            runsSection(model)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: Binding(get: { model.previewGroups != nil }, set: { if !$0 { model.closePreview() } })) { previewSheet(model) }
        .alert("Switch sync off", isPresented: $confirmingOff) {
            Button("Keep the entries") { model.switchOff(removeEntries: false) }
            Button("Remove Memorri's entries", role: .destructive) { model.switchOff(removeEntries: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Memorri made \(model.removalCount) \(model.removalCount == 1 ? "entry" : "entries") in Calendar and Reminders. Keep them, or remove them? Entries you made yourself are never removed.")
        }
        .alert(item: $model.moveRequest) { request in
            Alert(title: Text("Move Memorri's entries?"),
                  message: Text("\(request.count) \(request.count == 1 ? "entry" : "entries") made by Memorri will be created in \(request.newName) and removed from the old \(request.kind == .event ? "calendar" : "list"). Entries you made yourself stay where they are."),
                  primaryButton: .default(Text("Move")) { model.confirmMove() }, secondaryButton: .cancel())
        }
    }

    private func accessRow(_ model: CalendarSyncModel, _ kind: SyncEntryKind, _ name: String) -> some View {
        HStack {
            Image(systemName: model.access(kind) == .allowed ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(model.access(kind) == .allowed ? .green : .orange)
            Text("\(name): \(model.accessText(kind))")
            Spacer()
            switch model.access(kind) {
            case .allowed: EmptyView()
            case .notDetermined: Button("Allow") { model.requestAccess(kind) }.help("macOS asks you once. Memorri needs full access to read what it wrote, to notice edits and deletions")
            case .denied: Button("Open System Settings") { Self.openPrivacy(kind) }.help("Allow Memorri under Privacy & Security, then come back")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func openPrivacy(_ kind: SyncEntryKind) {
        let pane = kind == .event ? "Privacy_Calendars" : "Privacy_Reminders"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    private func picker(_ title: String, _ containers: [SyncContainer], selection: String?, access: SyncAccess, missing: Bool, notice: String?, help: String,
                        choose: @escaping (String?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(get: { selection ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                Text(access == .allowed ? "None chosen" : "Allow access first").tag("")
                ForEach(containers) { Text(SyncTargets.label($0)).tag($0.id) }
            }
            .disabled(access != .allowed)
            .help(help)
            if missing { Text("The chosen \(title.lowercased().contains("calendar") ? "calendar" : "list") no longer exists.").font(.callout).foregroundStyle(.orange) }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func runsSection(_ model: CalendarSyncModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent runs").font(.headline)
            if model.runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.runs.prefix(8)) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SyncWords.age(run.finishedAt, now: model.now)) · \(SyncWords.summary(run))").font(.callout)
                        ForEach(Array(run.detail.prefix(3).enumerated()), id: \.offset) { _, line in Text(line).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func previewSheet(_ model: CalendarSyncModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.previewIsFirst ? "First sync: this is what Memorri would write" : "What a sync would do").font(.title3).bold()
            Text("Nothing has been written. Only the calendar and list you chose are touched.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if (model.previewGroups ?? []).isEmpty { Text("Nothing to do: everything is already up to date.") }
                    ForEach(model.previewGroups ?? []) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title).font(.headline)
                            ForEach(Array(group.lines.prefix(200).enumerated()), id: \.offset) { _, line in Text(line).font(.callout).textSelection(.enabled) }
                            if group.lines.count > 200 { Text("and \(group.lines.count - 200) more").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Close") { model.closePreview() }.keyboardShortcut(.cancelAction)
                Button(model.confirmed ? "Sync now" : "Looks right, sync now") { model.syncNow() }
                    .keyboardShortcut(.defaultAction).disabled(!model.enabled)
            }
        }
        .padding(20).frame(width: 560, height: 460)
    }
}
