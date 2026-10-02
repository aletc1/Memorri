import AppKit
import MemorriCore
import SwiftUI

/// The menu-bar menu (see contracts/ui-contract.md).
struct MenuContent: View {
    let environment: AppEnvironment

    private var captureTitle: String {
        if let shortcut = environment.shortcuts.displayText { "Capture now   \(shortcut)" } else { "Capture now" }
    }

    private var searchTitle: String {
        if let shortcut = environment.shortcuts.searchDisplayText { "Search…   \(shortcut)" } else { "Search…" }
    }

    var body: some View {
        let status = environment.state.permissionStatus

        Text(environment.state.lastCaptureLine)
        Text(environment.state.analysisLine)
        Button(captureTitle) { environment.requestCapture(.menu) }
        Button("Capture window") { environment.requestWindowCapture(.menu) }
        if environment.analysis != nil {
            let paused = environment.state.analysisProgress.paused
            Button(paused ? "Resume analysis" : "Pause analysis") {
                Task { await environment.analysis?.pause(!paused) }
            }
        }
        Button("Items…") { environment.windows.show(.items) }
        Button(environment.state.reviewCount > 0 ? "Inbox (\(environment.state.reviewCount))" : "Inbox") { environment.showItems(scope: .inbox) }
        Button(searchTitle) { environment.searchPanel.show() }

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
