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
    /// The tallest an untitled strip as wide as a display can be and still count as the chrome of a full-screen application (its toolbar, shown
    /// under the menu bar when the pointer is at the top) and not as a window.
    static let screenStripHeight = 44.0

    /// Windows that cannot be seen are never chosen: fully transparent ones, and, when `screens` is given, ones that lie off every screen and
    /// untitled strips across a whole display (the toolbar a full-screen application keeps above the top edge, and shows under the menu bar).
    /// `candidates` run from the front window to the back one, as the system lists them.
    public static func pick(candidates: [WindowCandidate], frontmostProcessID: Int32?, ownProcessID: Int32, screens: [DesktopRect]? = nil) -> ActiveWindowChoice {
        guard let frontmostProcessID else { return .none }
        if frontmostProcessID == ownProcessID { return .ownWindow }
        let match = candidates.first { candidate in
            candidate.processID == frontmostProcessID && candidate.layer == 0 && candidate.isOnScreen && !candidate.frame.isEmpty && candidate.alpha > 0.05
                && (screens?.contains { candidate.frame.intersection($0) != nil } ?? true) && !isScreenStrip(candidate, screens: screens)
        }
        return match.map(ActiveWindowChoice.window) ?? .none
    }

    private static func isScreenStrip(_ candidate: WindowCandidate, screens: [DesktopRect]?) -> Bool {
        guard let screens, candidate.title == nil, candidate.frame.height <= screenStripHeight else { return false }
        return screens.contains { candidate.frame.width >= $0.width * 0.99 }
    }
}
