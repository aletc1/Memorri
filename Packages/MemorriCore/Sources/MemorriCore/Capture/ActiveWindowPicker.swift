import Foundation

/// What the active-window choice came to.
public enum ActiveWindowChoice: Sendable, Equatable {
    case window(WindowCandidate)
    /// Nothing qualifies.
    case none
    /// One of Memorri's own windows is in front, which is never captured.
    case ownWindow
}

/// Chooses the window a window capture takes (spec 013 FR-005, FR-007; research R2): the front-most ordinary window of the frontmost
/// application. macOS puts the key window of the active application in front of its other ordinary windows, so this is the window that has
/// keyboard focus in normal use, found without Accessibility permission.
public enum ActiveWindowPicker {
    /// `candidates` run from the front window to the back one, as the system lists them.
    public static func pick(candidates: [WindowCandidate], frontmostProcessID: Int32?, ownProcessID: Int32) -> ActiveWindowChoice {
        guard let frontmostProcessID else { return .none }
        if frontmostProcessID == ownProcessID { return .ownWindow }
        let match = candidates.first { $0.processID == frontmostProcessID && $0.layer == 0 && $0.isOnScreen && !$0.frame.isEmpty }
        return match.map(ActiveWindowChoice.window) ?? .none
    }
}
