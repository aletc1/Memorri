import AppKit
import MemorriCore

/// Keeps one copy of the app running. A second launch tells the running copy to open Settings
/// and quits at once, so the user sees the app is alive even when its icon is hidden.
enum SingleInstance {
    static let openSettingsNotification = Notification.Name("com.aletc1.memorri.openSettings")

    /// Call first thing at launch, before anything is created.
    static func exitIfAnotherCopyIsRunning() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aletc1.memorri"
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherPIDs = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
        guard SingleInstanceArbiter.shouldExit(ownPID: ownPID, otherPIDs: otherPIDs) else { return }

        DistributedNotificationCenter.default().postNotificationName(
            openSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        Thread.sleep(forTimeInterval: 0.2)   // let the notification leave before quitting
        exit(0)
    }

    /// In the running copy: open Settings when another launch asks for it.
    @MainActor
    static func observeSecondLaunch(_ onSecondLaunch: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: openSettingsNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onSecondLaunch() }
        }
    }
}
