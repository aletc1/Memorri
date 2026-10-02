import Foundation

/// One window of a capture, with only the part of it that can be seen and the text recognised there (spec 011, research R1).
public struct VisibleWindow: Sendable, Equatable {
    /// `w<stack index>` as the capture recorded it, or `all` for a capture read as one window.
    public let key: String
    public let appName: String?
    /// Never logged: titles can show the user's own content (ADR 0016).
    public let title: String?
    public let bundleID: String?
    /// In pixels of the picture, clipped to it.
    public let frame: PixelBox
    /// The frame minus the frames of every window in front of it, as rectangles that do not overlap.
    public let visible: [PixelBox]
    /// The visible area over the picture's area.
    public let visibleShare: Double
    /// The lines whose centre is in the visible part, with the numbers they have in the whole picture.
    public let lines: [RecognisedLine]

    public init(key: String, appName: String?, title: String?, bundleID: String?, frame: PixelBox, visible: [PixelBox], visibleShare: Double, lines: [RecognisedLine]) {
        self.key = key; self.appName = appName; self.title = title; self.bundleID = bundleID
        self.frame = frame; self.visible = visible; self.visibleShare = visibleShare; self.lines = lines
    }

    /// True when a point of the picture is in the visible part.
    public func shows(x: Double, y: Double) -> Bool {
        visible.contains { x >= Double($0.x) && x < Double($0.x + $0.width) && y >= Double($0.y) && y < Double($0.y + $0.height) }
    }
}

/// A picture split into the windows that can be read on their own.
public struct VisibleScreen: Sendable, Equatable {
    /// The key of the one window of a capture that has no usable stack of windows.
    public static let wholePicture = "all"
    /// A window with less than this share of the picture visible is not read.
    public static let minimumVisibleShare = 0.02
    /// A window with fewer lines than this is not read.
    public static let minimumLines = 3

    /// Front to back, the dropped windows removed. Never empty.
    public let windows: [VisibleWindow]
    /// Lines in no window: the menu bar, the dock, the wallpaper.
    public let desktopLines: [RecognisedLine]

    public init(windows: [VisibleWindow], desktopLines: [RecognisedLine]) {
        self.windows = windows; self.desktopLines = desktopLines
    }

    /// False when the capture is read as one window covering the picture (no stack, one window, or nothing left worth reading).
    public var perWindow: Bool { !(windows.count == 1 && windows[0].key == Self.wholePicture) }

    /// Windows of the system's own surfaces and of this app are never read. Their frames still hide what lies under them.
    static func isSystemSurface(_ window: WindowInfo) -> Bool {
        if let bundle = window.bundleID?.lowercased() {
            if bundle == MemorriCore.subsystem || bundle == "com.apple.dock" || bundle == "com.apple.controlcenter"
                || bundle == "com.apple.notificationcenterui" || bundle == "com.apple.windowmanager" { return true }
        }
        let name = window.appName?.lowercased()
        return name == "window server" || name == "memorri"
    }

    /// Splits the lines of a picture by the windows it showed. A capture that has no windows, windows without a stack order, or only one window
    /// (or whose windows all get dropped) is one window, `all`, with every line, as before this feature (FR-010).
    /// `minimumShare` and `minimumLines` are what a window must have to be read; a caller that only needs to know what covers what can lower them.
    /// With `chosenWindow` (a window capture, spec 013) the one recorded window is the window the user chose: it is kept whatever its size, number of lines
    /// or application, so it is always read and its name is always known.
    public static func split(lines: [RecognisedLine], windows: [WindowInfo], pictureWidth: Int, pictureHeight: Int,
                             minimumShare: Double = VisibleScreen.minimumVisibleShare, minimumLines: Int = VisibleScreen.minimumLines,
                             chosenWindow: Bool = false) -> VisibleScreen {
        let picture = PixelBox(x: 0, y: 0, width: pictureWidth, height: pictureHeight)
        let whole = VisibleScreen(windows: [VisibleWindow(key: wholePicture, appName: nil, title: nil, bundleID: nil, frame: picture, visible: [picture],
                                                          visibleShare: 1, lines: lines)], desktopLines: [])
        if chosenWindow {
            guard let chosen = windows.min(by: { ($0.stack ?? 0) < ($1.stack ?? 0) }), let frame = clip(chosen.frame, to: picture) else { return whole }
            let inside = lines.filter { contains(frame, x: $0.box.midX, y: $0.box.midY) }
            let outside = lines.filter { !contains(frame, x: $0.box.midX, y: $0.box.midY) }
            let share = Double(frame.width * frame.height) / Double(max(1, pictureWidth * pictureHeight))
            return VisibleScreen(windows: [VisibleWindow(key: "w\(chosen.stack ?? 0)", appName: chosen.appName, title: chosen.title, bundleID: chosen.bundleID,
                                                         frame: frame, visible: [frame], visibleShare: share, lines: inside)], desktopLines: outside)
        }
        guard windows.count > 1, windows.allSatisfy({ $0.stack != nil }) else { return whole }

        // Front to back; clip each frame to the picture. A window with nothing inside the picture is not on it.
        let ordered: [(info: WindowInfo, frame: PixelBox)] = windows.sorted { ($0.stack ?? 0) < ($1.stack ?? 0) }.compactMap { info in
            clip(info.frame, to: picture).map { (info, $0) }
        }
        var visibleParts: [[PixelBox]] = []
        for (index, window) in ordered.enumerated() {
            var parts = [window.frame]
            for front in ordered[..<index].map(\.frame) { parts = parts.flatMap { subtract(front, from: $0) } }
            visibleParts.append(parts)
        }
        // A line goes to the frontmost window whose frame holds its centre (that is the window whose visible part holds it).
        var owned = [[RecognisedLine]](repeating: [], count: ordered.count)
        var desktop: [RecognisedLine] = []
        for line in lines {
            if let index = ordered.firstIndex(where: { contains($0.frame, x: line.box.midX, y: line.box.midY) }) { owned[index].append(line) }
            else { desktop.append(line) }
        }
        let area = Double(max(1, pictureWidth * pictureHeight))
        let kept: [VisibleWindow] = ordered.enumerated().compactMap { index, window in
            guard !isSystemSurface(window.info) else { return nil }
            let share = Double(visibleParts[index].reduce(0) { $0 + $1.width * $1.height }) / area
            guard share >= minimumShare, owned[index].count >= minimumLines else { return nil }
            return VisibleWindow(key: "w\(window.info.stack ?? index)", appName: window.info.appName, title: window.info.title, bundleID: window.info.bundleID,
                                 frame: window.frame, visible: visibleParts[index], visibleShare: share, lines: owned[index])
        }
        return kept.isEmpty ? whole : VisibleScreen(windows: kept, desktopLines: desktop)
    }

    private static func contains(_ box: PixelBox, x: Double, y: Double) -> Bool {
        x >= Double(box.x) && x < Double(box.x + box.width) && y >= Double(box.y) && y < Double(box.y + box.height)
    }

    private static func clip(_ box: PixelBox, to picture: PixelBox) -> PixelBox? {
        let x0 = max(box.x, picture.x), y0 = max(box.y, picture.y)
        let x1 = min(box.x + box.width, picture.x + picture.width), y1 = min(box.y + box.height, picture.y + picture.height)
        return x1 > x0 && y1 > y0 ? PixelBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
    }

    /// `box` minus `cut`: up to four rectangles that do not overlap (above, below, left and right of the cut).
    private static func subtract(_ cut: PixelBox, from box: PixelBox) -> [PixelBox] {
        guard let overlap = clip(cut, to: box) else { return [box] }
        var parts: [PixelBox] = []
        if overlap.y > box.y { parts.append(PixelBox(x: box.x, y: box.y, width: box.width, height: overlap.y - box.y)) }
        let overlapBottom = overlap.y + overlap.height, boxBottom = box.y + box.height
        if overlapBottom < boxBottom { parts.append(PixelBox(x: box.x, y: overlapBottom, width: box.width, height: boxBottom - overlapBottom)) }
        if overlap.x > box.x { parts.append(PixelBox(x: box.x, y: overlap.y, width: overlap.x - box.x, height: overlap.height)) }
        let overlapRight = overlap.x + overlap.width, boxRight = box.x + box.width
        if overlapRight < boxRight { parts.append(PixelBox(x: overlapRight, y: overlap.y, width: boxRight - overlapRight, height: overlap.height)) }
        return parts
    }
}
