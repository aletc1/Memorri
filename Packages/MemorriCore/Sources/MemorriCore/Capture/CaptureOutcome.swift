/// What one capture run ended as.
public enum CaptureOutcome: Sendable, Equatable {
    case complete(displays: Int)
    case partial(captured: Int, of: Int)
    case failed(reason: String)
    /// macOS refused the capture; the app opens onboarding instead of showing an error line.
    case permissionDenied
}

/// What the top of the menu shows (FR-021). Not stored.
public enum LastCaptureResult: Sendable, Equatable {
    case complete
    case partial(captured: Int, of: Int)
    case failed(reason: String)
}
