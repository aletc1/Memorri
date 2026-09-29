import MemorriCore
import SwiftUI
import os

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
                Logger(subsystem: MemorriCore.subsystem, category: "permission")
                    .notice("permission status: \(status.rawValue, privacy: .public)")
            }
        }
        startPermissionPolling()
    }

    /// Follows the permission for as long as the app runs. A running process keeps the answer it
    /// had at launch and cannot see a grant or a revocation made afterwards, so every 2 seconds
    /// (and whenever the app becomes active) a freshly started copy of the app is asked what macOS
    /// says now. Each probe costs about 20 ms and a millisecond of CPU.
    private func startPermissionPolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.probePermission()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.probePermission() }
        }
    }

    private func probePermission() async {
        guard let granted = await screenRecording.isGrantedInFreshProcess() else { return }
        await permission.observeFreshProcess(granted: granted)
    }

    func checkPermission() {
        Task { await probePermission() }
    }

    /// Asks macOS for access first (shows the prompt and adds the app to the Screen Recording
    /// list, spike R5), then opens the System Settings pane.
    func openScreenRecordingSettings() {
        let granted = screenRecording.requestAccess()
        Logger(subsystem: MemorriCore.subsystem, category: "permission")
            .notice("requestAccess returned \(granted, privacy: .public)")
        // Give the system prompt a moment to appear before the pane takes the focus.
        Task { [screenRecording] in
            try? await Task.sleep(for: .seconds(1.5))
            screenRecording.openSystemSettings()
        }
    }

    /// Starts a new copy once this one has quit, so the single-instance check in the new copy
    /// does not see this one still running. Waits for this process to exit (at most 10 seconds).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = "i=0; while kill -0 \"$2\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open -n \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", path, pid]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    func requestCapture(_ trigger: CaptureTrigger) {
        Task { [captureService] in await captureService.request(trigger) }
    }

    /// The SwiftUI content of each window.
    private func content(for id: WindowID) -> AnyView {
        switch id {
        case .inbox: AnyView(PlaceholderView.inbox)
        case .search: AnyView(PlaceholderView.search)
        case .settings: AnyView(SettingsView(environment: self))
        case .onboarding: AnyView(OnboardingView(environment: self))
        }
    }
}
