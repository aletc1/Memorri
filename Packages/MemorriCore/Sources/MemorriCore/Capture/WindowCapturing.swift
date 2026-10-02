import CoreGraphics
import Foundation

/// What a capture took: every display (the full-screen capture) or one window (spec 013).
public enum CaptureScope: String, Sendable, Codable {
    case displays
    case window
}

/// A rectangle on the desktop in points, origin at the top left of the main display (y grows downwards), as the system lists window frames.
public struct DesktopRect: Sendable, Equatable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part of both rectangles, or nil when they share no area.
    public func intersection(_ other: DesktopRect) -> DesktopRect? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return DesktopRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// One window as the system lists it, front to back. The application name and title stay local like every window name (ADR 0016).
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let processID: Int32
    public let layer: Int
    public let isOnScreen: Bool
    public let frame: DesktopRect
    public let appName: String?
    public let bundleID: String?
    public let title: String?

    public init(windowID: UInt32, processID: Int32, layer: Int = 0, isOnScreen: Bool = true, frame: DesktopRect,
                appName: String? = nil, bundleID: String? = nil, title: String? = nil) {
        self.windowID = windowID; self.processID = processID; self.layer = layer; self.isOnScreen = isOnScreen; self.frame = frame
        self.appName = appName; self.bundleID = bundleID; self.title = title
    }
}

/// The one picture of a window capture: what was on the screen inside the window's outline, at native pixels.
public struct WindowCaptureResult: @unchecked Sendable {
    public let image: CGImage
    public let scale: Double
    public let displayID: UInt32
    public let displayName: String?
    /// The recorded rectangle on the desktop, clipped to the screens.
    public let frame: DesktopRect
    public let appName: String?
    public let bundleID: String?
    public let title: String?

    public init(image: CGImage, scale: Double, displayID: UInt32, displayName: String?, frame: DesktopRect,
                appName: String?, bundleID: String?, title: String?) {
        self.image = image; self.scale = scale; self.displayID = displayID; self.displayName = displayName; self.frame = frame
        self.appName = appName; self.bundleID = bundleID; self.title = title
    }
}

public enum WindowCaptureFailure: Error, Sendable, Equatable {
    /// macOS refused because Screen Recording is missing or revoked.
    case permissionDenied
    /// The frontmost application has no window that qualifies.
    case noWindow
    /// One of Memorri's own windows is in front.
    case ownWindow
    case other(String)
}

public protocol WindowCapturing: Sendable {
    /// One picture of the active window. Throws `WindowCaptureFailure`.
    func captureActiveWindow() async throws -> WindowCaptureResult
}

/// Shows where a window capture was taken. Returns at once; the outline removes itself.
public protocol CaptureOutlining: Sendable {
    func showOutline(for frame: DesktopRect) async
}

extension CaptureOutlining {
    public func showOutline(for frame: DesktopRect) async {}
}
