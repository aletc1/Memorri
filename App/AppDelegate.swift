import AppKit
import MemorriCore
import os

/// Lifecycle hooks. The single-instance check (US4) is added here later.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
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
