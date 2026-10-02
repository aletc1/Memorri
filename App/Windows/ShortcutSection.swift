import KeyboardShortcuts
import SwiftUI

/// Recorders for the capture, window-capture and search shortcuts, each with clear (the recorder's own x button), reset to default
/// and the reason when a shortcut is refused or missing.
struct ShortcutSection: View {
    let shortcuts: ShortcutAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Capture shortcut:", action: .capture)
            row("Capture window shortcut:", action: .window)
            row("Search shortcut:", action: .search)
        }
    }

    @ViewBuilder
    private func row(_ title: String, action: ShortcutAdapter.Action) -> some View {
        HStack {
            KeyboardShortcuts.Recorder(title, name: action.name) { shortcut in
                shortcuts.recorderChanged(shortcut, for: action)
            }
            Button("Reset to default") { shortcuts.resetToDefault(action) }
        }
        if let message = shortcuts.message(for: action) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}
