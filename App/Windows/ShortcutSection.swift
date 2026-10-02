import KeyboardShortcuts
import SwiftUI

/// Recorder for the capture shortcut, with clear (the recorder's own x button), reset to default
/// and the reason when a shortcut is refused.
struct ShortcutSection: View {
    let shortcuts: ShortcutAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                KeyboardShortcuts.Recorder("Capture shortcut:", name: .capture) { shortcut in
                    shortcuts.recorderChanged(shortcut)
                }
                Button("Reset to default") { shortcuts.resetToDefault() }
            }
            if let message = shortcuts.rejectionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                KeyboardShortcuts.Recorder("Search shortcut:", name: .search) { shortcut in
                    shortcuts.recorderChanged(shortcut, for: .search)
                }
                Button("Reset to default") { shortcuts.resetToDefault(.search) }
            }
            if let message = shortcuts.searchRejectionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }
}
