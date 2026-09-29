import AppKit
import MemorriCore
import os

/// Lifecycle hooks: onboarding at the first launch and the second-launch signal.
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
}
