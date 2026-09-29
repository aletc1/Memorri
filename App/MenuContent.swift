import AppKit
import MemorriCore
import SwiftUI

/// The menu-bar menu (see contracts/ui-contract.md).
struct MenuContent: View {
    let environment: AppEnvironment

    var body: some View {
        let status = environment.state.permissionStatus

        Button("Capture now") { environment.requestCapture(.menu) }
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
