import SwiftUI

@main
struct MemorriApp: App {
    var body: some Scene {
        MenuBarExtra {
            Button("Quit Memorri") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)
    }
}
