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
    /// `nil` when the storage could not be opened at all.
    let storage: StorageContext?
    /// The figures and clean-up shown in Settings; `nil` when the storage is unavailable.
    let storageServices: (stats: StorageStats, cleanup: CleanupService)?
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "storage")

    init() {
        feedbackSettings = CaptureFeedbackSettings(store: settingsStore)
        permission = PermissionMonitor(checker: screenRecording)
        feedback = FeedbackAdapter(state: state)
        let windows = self.windows
        let state = self.state
        let opened = Self.openStorage(settingsStore: settingsStore)
        storage = opened.storage
        if let context = opened.storage, let store = context.store {
            storageServices = (StorageStats(paths: context.paths, store: store),
                               CleanupService(paths: context.paths, store: store, files: context.files))
        } else {
            storageServices = nil
        }
        captureService = CaptureRequestService(
            runner: opened.runner,
            permission: permission,
            feedback: feedback,
            settings: feedbackSettings,
            onOutcome: { outcome in Task { @MainActor in state.record(outcome) } },
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
        startClockTick()
        if let storage { StartupAlerts.showIfNeeded(for: storage) }
    }

    /// Opens the storage and builds the capture pipeline. When storage cannot be used, capturing
    /// reports why instead of crashing.
    private static func openStorage(settingsStore: any SettingsStore) -> (runner: any CaptureRunning, storage: StorageContext?) {
        do {
            let context = try StorageBootstrap.start(paths: try AppPaths.standard())
            guard let store = context.store else {
                return (UnavailableCaptureRunner(reason: context.capturingDisabledReason ?? "could not open the capture storage"), context)
            }
            let pipeline = CapturePipeline(capturer: ScreenCaptureKitCapturer(), encoder: HEICImageEncoder(),
                                           disk: DiskSpaceAdapter(), files: context.files, store: store,
                                           paths: context.paths, settings: StorageSettings(store: settingsStore))
            return (pipeline, context)
        } catch {
            logger.error("storage unavailable: \(error.localizedDescription, privacy: .public)")
            return (UnavailableCaptureRunner(reason: "could not open the capture storage"), nil)
        }
    }

    private func startClockTick() {
        Task { @MainActor [state] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                state.now = Date()
            }
        }
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
