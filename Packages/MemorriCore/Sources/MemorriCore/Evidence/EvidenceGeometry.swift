import Foundation

/// A rectangle of the full-resolution picture, top-left origin, in pixels.
public struct PixelRegion: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Which part of a picture proves a finding (spec 006, research R2). Pure.
public enum EvidenceGeometry {
    public static let maxWidth = 1600
    /// Bumped when the shape of a cut-out changes; older cut-outs are made again while their picture is stored.
    /// 1: the cited lines with a small margin. 2: the cited lines in the context around them. 3: the window that holds the cited lines
    /// (or a 1400 x 800 part of it), for findings that have a window; findings without one keep the shape of 2.
    public static let version = 3
    /// A window larger than this is not cut out whole; the part around the cited lines is.
    static let windowMaxWidth = 1400
    static let windowMaxHeight = 800
    static let minimumMargin = 24
    static let marginShare = 0.15
    /// A cut-out shows at least this share of the picture's width and height, around the cited lines, so the calendar block or the window
    /// that holds them is in view and not only a line of text.
    static let contextWidthShare = 0.5
    static let contextHeightShare = 0.35

    /// The union of the boxes grown by a margin of 24 px or 15% of the union's height (whichever is larger), widened to at least half
    /// the picture's width and 35% of its height around the union, kept inside the picture. Nil when there are no boxes or nothing of
    /// them is inside the picture.
    public static func region(lines: [PixelBox], pictureWidth: Int, pictureHeight: Int) -> PixelRegion? {
        guard !lines.isEmpty, pictureWidth > 0, pictureHeight > 0 else { return nil }
        let left = lines.map(\.x).min()!, top = lines.map(\.y).min()!
        let right = lines.map { $0.x + $0.width }.max()!, bottom = lines.map { $0.y + $0.height }.max()!
        guard right > 0, bottom > 0, left < pictureWidth, top < pictureHeight else { return nil }
        let margin = max(minimumMargin, Int((marginShare * Double(bottom - top)).rounded(.up)))
        let (x0, x1) = span(low: left, high: right, margin: margin, share: contextWidthShare, size: pictureWidth)
        let (y0, y1) = span(low: top, high: bottom, margin: margin, share: contextHeightShare, size: pictureHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The window's frame clipped to the picture; when that is larger than 1400 x 800, a 1400 x 800 rectangle (or less on an axis the frame
    /// is shorter on) centred on the cited lines with their margin, shifted to stay inside the frame and holding the cited lines when they
    /// fit. Nil when the frame has nothing inside the picture.
    public static func region(lines: [PixelBox], window: PixelBox, pictureWidth: Int, pictureHeight: Int) -> PixelRegion? {
        guard pictureWidth > 0, pictureHeight > 0 else { return nil }
        let left = max(0, window.x), top = max(0, window.y)
        let right = min(pictureWidth, window.x + window.width), bottom = min(pictureHeight, window.y + window.height)
        guard right > left, bottom > top else { return nil }
        guard right - left > windowMaxWidth || bottom - top > windowMaxHeight else {
            return PixelRegion(x: left, y: top, width: right - left, height: bottom - top)
        }
        // The cited lines, kept to the frame; with none inside, the middle of the frame.
        let inside = lines.compactMap { box -> (Int, Int, Int, Int)? in
            let l = max(left, box.x), t = max(top, box.y), r = min(right, box.x + box.width), b = min(bottom, box.y + box.height)
            return r > l && b > t ? (l, t, r, b) : nil
        }
        let low = (x: inside.map { $0.0 }.min() ?? (left + right) / 2, y: inside.map { $0.1 }.min() ?? (top + bottom) / 2)
        let high = (x: inside.map { $0.2 }.max() ?? (left + right) / 2, y: inside.map { $0.3 }.max() ?? (top + bottom) / 2)
        let margin = max(minimumMargin, Int((marginShare * Double(high.y - low.y)).rounded(.up)))
        let (x0, x1) = windowSpan(low: low.x, high: high.x, margin: margin, length: min(right - left, windowMaxWidth), from: left, to: right)
        let (y0, y1) = windowSpan(low: low.y, high: high.y, margin: margin, length: min(bottom - top, windowMaxHeight), from: top, to: bottom)
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// One axis of a window cut: `length` centred on `low...high`, inside `from...to`, covering `low...high` and its margin when they fit
    /// (and the start of the lines when they do not).
    private static func windowSpan(low: Int, high: Int, margin: Int, length: Int, from: Int, to: Int) -> (Int, Int) {
        let wanted = max(low - margin, from), wantedEnd = min(high + margin, to)
        var start = (wanted + wantedEnd) / 2 - length / 2
        if wantedEnd - wanted <= length {
            start = max(min(start, wanted), wantedEnd - length)
        } else {
            start = wanted
        }
        start = min(max(from, start), to - length)
        return (start, start + length)
    }

    /// One axis: the range around `low...high` that is at least `share` of `size` (and covers the margin), centred on it, shifted to fit
    /// inside `0...size`, and always covering the part of `low...high` that is inside.
    private static func span(low: Int, high: Int, margin: Int, share: Double, size: Int) -> (Int, Int) {
        let length = min(size, max(high - low + 2 * margin, Int(share * Double(size))))
        var start = (low + high) / 2 - length / 2
        start = min(max(0, start), size - length)
        var end = start + length
        start = min(start, max(0, low))
        end = max(end, min(size, high))
        return (start, end)
    }

    /// The size the cut-out is saved at: its own size, or scaled down to 1600 px wide.
    public static func outputSize(for region: PixelRegion) -> (width: Int, height: Int) {
        guard region.width > maxWidth else { return (region.width, region.height) }
        let scale = Double(maxWidth) / Double(region.width)
        return (maxWidth, max(1, Int((Double(region.height) * scale).rounded())))
    }
}
