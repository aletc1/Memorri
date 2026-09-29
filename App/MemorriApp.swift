import SwiftUI

@main
struct MemorriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Created on first use, which is after the single-instance check in `init`.
    private var environment: AppEnvironment { AppEnvironment.shared }

    init() {
        ScreenRecordingAdapter.runProbeIfRequested()
        SingleInstance.exitIfAnotherCopyIsRunning()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(environment: environment)
        } label: {
            Image(environment.state.isFlashing ? "MenuBarIconFlash" : "MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)
    }
}
