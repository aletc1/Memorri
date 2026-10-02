import Foundation

/// One window that was visible on a display when it was captured. Titles can show the user's own
/// content, so they are stored only locally, deleted with the capture and never logged (ADR 0016).
public struct WindowInfo: Sendable, Equatable {
    public let appName: String?
    public let bundleID: String?
    public let title: String?
    /// In the pixel space of the display's picture, clipped to it.
    public let frame: PixelBox
    /// Its place in the stack of windows on the display, 0 for the one in front; nil when it was not recorded (captures made before
    /// the stack was kept, and fixtures).
    public let stack: Int?

    public init(appName: String?, bundleID: String?, title: String?, frame: PixelBox, stack: Int? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.stack = stack
    }
}

/// Where the analysis reads a picture's windows from.
public protocol WindowProviding: Sendable {
    func windows(imageID: String) throws -> [WindowInfo]
    /// Whether the picture is a window capture (spec 013); a provider that does not know says full-screen.
    func scope(imageID: String) throws -> CaptureScope
}

extension WindowProviding {
    public func scope(imageID: String) throws -> CaptureScope { .displays }
}

extension CaptureStore: WindowProviding {}

/// Which windows are kept with a picture: the biggest ones that can be seen on it.
public enum WindowSelection {
    /// Enough to tell the user's applications and customers apart without keeping every palette and tooltip.
    public static let maximum = 20

    /// Clips every frame to the picture, drops windows with nothing visible, and keeps the `maximum` largest, biggest first.
    /// Windows of the same size keep the order they were given in (front to back).
    public static func select(_ windows: [WindowInfo], pictureWidth: Int, pictureHeight: Int) -> [WindowInfo] {
        let clipped: [WindowInfo] = windows.compactMap { window in
            let f = window.frame
            let x0 = max(f.x, 0), y0 = max(f.y, 0)
            let x1 = min(f.x + f.width, pictureWidth), y1 = min(f.y + f.height, pictureHeight)
            guard x1 > x0, y1 > y0 else { return nil }
            return WindowInfo(appName: window.appName, bundleID: window.bundleID, title: window.title,
                              frame: PixelBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0), stack: window.stack)
        }
        let ordered = clipped.enumerated().sorted { a, b in
            let areaA = a.element.frame.width * a.element.frame.height, areaB = b.element.frame.width * b.element.frame.height
            return areaA != areaB ? areaA > areaB : a.offset < b.offset
        }
        return ordered.prefix(maximum).map(\.element)
    }
}
