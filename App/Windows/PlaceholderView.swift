import SwiftUI

/// Stand-in for a feature that a later spec builds (Inbox: spec 006, Search: spec 007).
struct PlaceholderView: View {
    let message: String

    var body: some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let inbox = PlaceholderView(message: "The Inbox is not built yet. It arrives in a later version.")
    static let search = PlaceholderView(message: "Search is not built yet. It arrives in a later version.")
}
