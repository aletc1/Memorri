import MemorriCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, permissions, ollama, analysis, storage, calendarSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .ollama: "Ollama"
        case .analysis: "Analysis"
        case .storage: "Storage"
        case .calendarSync: "Calendar sync"
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
