import MemorriCore
import SwiftUI

/// Creates the shared services once at launch and connects them to their system adapters.
@MainActor
final class AppEnvironment {
    /// One environment for the whole app; the app delegate and the SwiftUI scene both use it.
    static let shared = AppEnvironment()

    let state = AppState()
    let screenRecording = ScreenRecordingAdapter()
    let settingsStore: any SettingsStore = UserDefaultsSettingsStore()
    let feedbackSettings: CaptureFeedbackSettings
    let permission: PermissionMonitor
    let windows = WindowCoordinator()
    let feedback: FeedbackAdapter
    let captureService: CaptureRequestService
    let shortcuts: ShortcutAdapter

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
        shortcuts = ShortcutAdapter(onCapture: { [captureService] in
            Task { await captureService.request(.shortcut) }
        })
        self.windows.contentProvider = { [unowned self] id in self.content(for: id) }

        Task { [state, permission] in
            for await status in await permission.statusUpdates() {
                state.permissionStatus = status
            }
        }
        startPermissionPolling()
    }

    /// Re-reads the permission every 2 seconds for as long as the app runs, and whenever the app
    /// becomes active, so a grant or a revocation shows up without any button press.
    private func startPermissionPolling() {
        Task { [permission] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await permission.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [permission] _ in
            Task { await permission.refresh() }
        }
    }

    func checkPermission() {
        Task { [permission] in await permission.refresh() }
    }

    /// Asks macOS for access first (shows the prompt and adds the app to the Screen Recording
    /// list, spike R5), then opens the System Settings pane.
    func openScreenRecordingSettings() {
        screenRecording.requestAccess()
        screenRecording.openSystemSettings()
    }

    /// Starts a new copy shortly after this one quits, so the single-instance check in the
    /// new copy does not see this one still running.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "sh", path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    func requestCapture(_ trigger: CaptureTrigger) {
        Task { [captureService] in await captureService.request(trigger) }
    }

    /// Window content. Onboarding and Settings get their real views in later user stories.
    private func content(for id: WindowID) -> AnyView {
        switch id {
        case .inbox: AnyView(PlaceholderView.inbox)
        case .search: AnyView(PlaceholderView.search)
        case .settings: AnyView(ShortcutSection(shortcuts: shortcuts).padding(30))
        case .onboarding: AnyView(OnboardingView(environment: self))
        }
    }
}
