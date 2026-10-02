import MemorriCore
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, permissions, ollama, analysis, storage, calendarSync, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .ollama: "Ollama"
        case .analysis: "Analysis"
        case .storage: "Storage"
        case .calendarSync: "Calendar sync"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .ollama: "cpu"
        case .analysis: "text.magnifyingglass"
        case .storage: "internaldrive"
        case .calendarSync: "calendar"
        case .diagnostics: "stethoscope"
        }
    }

}

/// The Settings window: a sidebar of sections with the detail on the right.
struct SettingsView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            detail(for: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettings(environment: environment)
        case .permissions:
            VStack(alignment: .leading, spacing: 12) {
                Text("Screen Recording").font(.headline)
                PermissionControls(environment: environment)
            }
            .padding(24)
        case .storage:
            StorageSettingsView(environment: environment)
        case .ollama:
            OllamaSettingsView(environment: environment)
        case .analysis:
            AnalysisSettingsView(environment: environment)
        case .calendarSync:
            CalendarSyncView(environment: environment)
        case .diagnostics:
            DiagnosticsView(environment: environment)
        }
    }
}

private struct GeneralSettings: View {
    let environment: AppEnvironment
    @State private var flashIcon = true
    @State private var playSound = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ShortcutSection(shortcuts: environment.shortcuts)

            VStack(alignment: .leading, spacing: 8) {
                Text("When a capture is requested").font(.headline)
                Toggle("Flash the menu-bar icon", isOn: $flashIcon)
                Toggle("Play a sound", isOn: $playSound)
            }

            LoginItemRow()

            NotificationsRow(environment: environment)
        }
        .padding(24)
        .onAppear {
            flashIcon = environment.feedbackSettings.flashIcon
            playSound = environment.feedbackSettings.playSound
        }
        .onChange(of: flashIcon) { _, value in environment.feedbackSettings.flashIcon = value }
        .onChange(of: playSound) { _, value in environment.feedbackSettings.playSound = value }
    }
}

/// `Notify me when new items arrive` with the state of macOS's permission (spec 010 FR-013).
private struct NotificationsRow: View {
    let environment: AppEnvironment
    @State private var enabled = true
    @State private var permission: SyncAccess = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.headline)
            Toggle("Notify me when new items arrive", isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                environment.notifications?.settings.enabled = value
                if value, permission == .notDetermined { Task { _ = await environment.notifications?.centre.authorised(); await load() } }
            }))
            .help("One quiet notice such as 3 new items, 1 needs review, after a burst of captures. None while the Items window is in front")
            if enabled, permission == .denied {
                HStack {
                    Text("macOS does not allow notifications from Memorri.").font(.callout).foregroundStyle(.orange)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if enabled, permission == .notDetermined {
                Text("macOS will ask the first time there is something to announce.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func load() async {
        enabled = environment.notifications?.settings.enabled ?? true
        permission = await environment.notifications?.centre.permission() ?? .notDetermined
    }
}

/// `Open Memorri at login`: the switch shows what macOS says, so removing the item in System Settings turns it off (spec 010 FR-014).
private struct LoginItemRow: View {
    private let item = LoginItem(controller: ServiceManagementLoginItem())
    @State private var status = LoginItemStatus.off
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start").font(.headline)
            Toggle("Open Memorri at login", isOn: Binding(get: { status != .off }, set: { value in
                do { status = try item.setOn(value); message = nil } catch { status = item.status; message = "macOS did not allow it: \(error.localizedDescription)" }
            }))
            .help("Starts the menu-bar app when you log in, so the capture shortcut works without opening anything")
            if let note = item.note, status == .requiresApproval {
                HStack {
                    Text(note).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
        }
        .onAppear { status = item.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = item.status }
    }
}
