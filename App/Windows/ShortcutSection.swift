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
        }
    }
}
