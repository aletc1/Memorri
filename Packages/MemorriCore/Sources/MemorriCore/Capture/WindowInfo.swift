import Foundation

/// One window that was visible on a display when it was captured. Titles can show the user's own
/// content, so they are stored only locally, deleted with the capture and never logged (ADR 0016).
public struct WindowInfo: Sendable, Equatable {
    public let appName: String?
    public let bundleID: String?
    public let title: String?
    /// In the pixel space of the display's picture, clipped to it.
    public let frame: PixelBox

    public init(appName: String?, bundleID: String?, title: String?, frame: PixelBox) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
    }
}
