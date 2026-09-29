import MemorriCore
import SwiftUI

/// Creates the shared services once at launch and connects them to their system adapters.
@MainActor
final class AppEnvironment {
    let state = AppState()
    let screenRecording = ScreenRecordingAdapter()
    let settingsStore: any SettingsStore = UserDefaultsSettingsStore()
    let feedbackSettings: CaptureFeedbackSettings
    let permission: PermissionMonitor
    let windows = WindowCoordinator()
    let feedback: FeedbackAdapter
    let captureService: CaptureRequestService

    init() {
        feedbackSettings = CaptureFeedbackSettings(store: settingsStore)
        permission = PermissionMonitor(checker: screenRecording)
        feedback = FeedbackAdapter(state: state)
        let windows = self.windows
        captureService = CaptureRequestService(
            permission: permission,
            feedback: feedback,
            settings: feedbackSettings,
            onNeedsOnboarding: { Task { @MainActor in windows.show(.onboarding) } }
        )
        self.windows.contentProvider = { [unowned self] id in self.content(for: id) }

        Task { [state, permission] in
            for await status in await permission.statusUpdates() {
                state.permissionStatus = status
            }
        }
    }

    func requestCapture(_ trigger: CaptureTrigger) {
        Task { [captureService] in await captureService.request(trigger) }
    }

    /// Window content. Onboarding and Settings get their real views in later user stories.
    private func content(for id: WindowID) -> AnyView {
        switch id {
        case .inbox: AnyView(PlaceholderView.inbox)
        case .search: AnyView(PlaceholderView.search)
        case .settings, .onboarding: AnyView(Text(id.title).padding(40))
        }
    }
}
