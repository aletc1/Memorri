import AppKit
import MemorriCore
import os

/// Lifecycle hooks: onboarding at the first launch, and Settings when the app is opened again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        SingleInstance.observeSecondLaunch { environment.windows.show(.settings) }
        Task {
            let status = await environment.permission.status
            Logger(subsystem: MemorriCore.subsystem, category: "permission")
                .notice("permission at launch: \(status.rawValue, privacy: .public)")
            if OnboardingPolicy(store: environment.settingsStore).decideAtLaunch(status: status) {
                environment.windows.show(.onboarding)
            }
        }
    }

    /// Clicking the app in Finder or the Dock while it runs sends a "reopen" event instead of
    /// starting a second copy. Answer it like a second launch: show Settings (FR-014).
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppEnvironment.shared.windows.show(.settings)
        return false
    }
}
