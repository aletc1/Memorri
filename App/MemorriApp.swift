import SwiftUI

@main
struct MemorriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(environment: environment)
        } label: {
            Image(environment.state.isFlashing ? "MenuBarIconFlash" : "MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)
    }
}
