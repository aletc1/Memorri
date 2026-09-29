import MemorriCore
import SwiftUI

/// Creates the shared services once at launch and connects them to their system adapters.
@MainActor
final class AppEnvironment {
    let screenRecording = ScreenRecordingAdapter()
    let settingsStore: any SettingsStore = UserDefaultsSettingsStore()
    let feedbackSettings: CaptureFeedbackSettings
    let permission: PermissionMonitor
    let windows = WindowCoordinator()

    init() {
        feedbackSettings = CaptureFeedbackSettings(store: settingsStore)
        permission = PermissionMonitor(checker: screenRecording)
        windows.contentProvider = { [unowned self] id in self.content(for: id) }
    }

    /// Window content. Real views replace these stubs in the user story phases.
    private func content(for id: WindowID) -> AnyView {
        AnyView(Text(id.title).padding(40))
    }
}
