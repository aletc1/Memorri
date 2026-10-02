import SwiftUI

/// A tooltip drawn by the app. The system one (`.help`) is not shown while Memorri is not the active app, which is its normal state,
/// so the header explains its controls with this one: it appears under the control after half a second of hovering.
private struct HoverTip: ViewModifier {
    let text: String
    let trailing: Bool
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard inside else { shown = false; return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { shown = true }
                }
            }
            .overlay(alignment: trailing ? .bottomTrailing : .bottom) {
                if shown {
                    Text(text)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .frame(width: text.count > 30 ? 240 : nil, alignment: .leading)
                        .fixedSize(horizontal: text.count <= 30, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .shadow(radius: 3, y: 1)
                        .alignmentGuide(.bottom) { $0[.top] - 6 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(100)
                }
            }
            .help(text)
    }
}

extension View {
    /// Explains a control on hover. Use `trailing` near the right edge of the window so the text does not run off it.
    func tip(_ text: String, trailing: Bool = false) -> some View { modifier(HoverTip(text: text, trailing: trailing)) }
}
