/// What one capture run ended as.
public enum CaptureOutcome: Sendable, Equatable {
    case complete(displays: Int)
    case partial(captured: Int, of: Int)
    case failed(reason: String)
    /// macOS refused the capture; the app opens onboarding instead of showing an error line.
    case permissionDenied
    /// One window was captured (spec 013). The application name is only for the menu line and is never logged.
    case windowComplete(app: String?)
    /// A window capture found no window to take.
    case noWindow(ActiveWindowReason)
}

/// Why a window capture had no window to take.
public enum ActiveWindowReason: Sendable, Equatable {
    /// The frontmost application has no window that qualifies.
    case none
    /// One of Memorri's own windows is in front.
    case ownWindow

    public var message: String {
        switch self {
        case .none: "no window to capture"
        case .ownWindow: "Memorri's own windows are not captured"
        }
    }
}

/// What the top of the menu shows (FR-021). Not stored.
public enum LastCaptureResult: Sendable, Equatable {
    case complete
    case partial(captured: Int, of: Int)
    case failed(reason: String)
    case window(app: String?)
}
