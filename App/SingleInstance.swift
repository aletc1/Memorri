import AppKit
import MemorriCore
import os

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
        // Keep the run loop turning briefly: the notification is only handed to the system from there.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        exit(0)
    }

    /// In the running copy: open Settings when another launch asks for it.
    /// The observer asks for immediate delivery: an agent app is rarely the active app, and macOS
    /// holds back distributed notifications for inactive apps otherwise.
    @MainActor
    static func observeSecondLaunch(_ onSecondLaunch: @escaping @MainActor () -> Void) {
        let observer = SecondLaunchObserver(onSecondLaunch)
        DistributedNotificationCenter.default().addObserver(
            observer,
            selector: #selector(SecondLaunchObserver.handle),
            name: openSettingsNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        secondLaunchObserver = observer
    }

    @MainActor private static var secondLaunchObserver: SecondLaunchObserver?
}

private final class SecondLaunchObserver: NSObject {
    private let action: @MainActor () -> Void

    @MainActor
    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func handle(_ notification: Notification) {
        Logger(subsystem: MemorriCore.subsystem, category: "lifecycle")
            .notice("second launch signal received")
        let action = self.action
        Task { @MainActor in action() }
    }
}
