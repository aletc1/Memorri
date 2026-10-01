import CoreGraphics
import Foundation

/// One display's picture at full native resolution, without the pointer.
public struct CapturedDisplay: @unchecked Sendable {
    public let displayID: UInt32
    public let name: String?
    public let image: CGImage
    public let scale: Double
    /// The windows visible on this display, largest first (empty when they could not be listed).
    public let windows: [WindowInfo]

    public init(displayID: UInt32, name: String?, image: CGImage, scale: Double, windows: [WindowInfo] = []) {
        self.displayID = displayID
        self.name = name
        self.image = image
        self.scale = scale
        self.windows = windows
    }
}

public enum CaptureFailure: Error, Sendable, Equatable {
    /// macOS refused because Screen Recording is missing or revoked (SCStreamError -3801, spike S2).
    case permissionDenied
    case noDisplays
    case other(String)
}

public struct DisplayCaptureResult: Sendable {
    public let displays: [CapturedDisplay]
    /// Displays that were present at the start but could not be captured.
    public let failedDisplayCount: Int

    public init(displays: [CapturedDisplay], failedDisplayCount: Int) {
        self.displays = displays
        self.failedDisplayCount = failedDisplayCount
    }
}

public protocol DisplayCapturing: Sendable {
    /// One picture per distinct display (mirror sets count once). A display that fails is counted
    /// in `failedDisplayCount` and does not stop the others. Throws `CaptureFailure`.
    func captureAllDisplays() async throws -> DisplayCaptureResult
}

public protocol DiskSpaceChecking: Sendable {
    func freeBytes(at url: URL) throws -> Int64
}
