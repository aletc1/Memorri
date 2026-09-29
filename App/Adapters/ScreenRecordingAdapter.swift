import AppKit
import CoreGraphics
import MemorriCore

/// Talks to macOS about the Screen Recording permission. Never captures screen content.
struct ScreenRecordingAdapter: ScreenRecordingChecking {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// `CGPreflightScreenCaptureAccess` reads the current state without prompting.
    func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt (once) and adds the app to the Screen Recording list.
    /// Without this call the app may only be listed under "system audio only" (spike R5).
    @discardableResult
    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
