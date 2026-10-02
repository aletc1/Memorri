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
    /// 1: the cited lines with a small margin. 2: the cited lines in the context around them.
    public static let version = 2
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
