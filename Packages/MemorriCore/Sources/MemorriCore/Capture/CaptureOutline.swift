import Foundation

/// One display's share of the outline: the rectangle to stroke, in that display's own coordinates (origin at its top left, y growing downwards).
public struct OutlineSegment: Sendable, Equatable {
    public let displayIndex: Int
    public let rect: DesktopRect

    public init(displayIndex: Int, rect: DesktopRect) { self.displayIndex = displayIndex; self.rect = rect }
}

/// Where the red outline of a window capture is drawn (spec 013, research R8). The app turns each segment into a panel on the display; flipping
/// y for AppKit's coordinates is done there.
public enum CaptureOutlineGeometry {
    /// The part of `frame` on each display (in desktop points, top-left origin), in the order of `displays`. What is off every display is left out.
    public static func segments(for frame: DesktopRect, displays: [DesktopRect]) -> [OutlineSegment] {
        guard !frame.isEmpty else { return [] }
        return displays.enumerated().compactMap { index, display in
            frame.intersection(display).map { part in
                OutlineSegment(displayIndex: index, rect: DesktopRect(x: part.x - display.x, y: part.y - display.y, width: part.width, height: part.height))
            }
        }
    }
}
