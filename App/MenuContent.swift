import AppKit
import MemorriCore
import SwiftUI

/// The menu-bar menu (see contracts/ui-contract.md).
struct MenuContent: View {
    let environment: AppEnvironment

    private var captureTitle: String {
        if let shortcut = environment.shortcuts.displayText { "Capture now   \(shortcut)" } else { "Capture now" }
    }

    var body: some View {
        let status = environment.state.permissionStatus

        Button(captureTitle) { environment.requestCapture(.menu) }
        Button("Inbox") { environment.windows.show(.inbox) }
        Button("Search") { environment.windows.show(.search) }

        Divider()

        if status != .granted {
            Button(status == .restartRequired ? "Restart to finish setup…" : "Grant Screen Recording access…") {
                environment.windows.show(.onboarding)
            }
        }
        Button("Settings…") { environment.windows.show(.settings) }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Memorri") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
