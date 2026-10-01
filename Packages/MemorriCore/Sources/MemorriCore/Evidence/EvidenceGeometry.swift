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
    static let minimumMargin = 24
    static let marginShare = 0.15

    /// The union of the boxes grown by a margin of 24 px or 15% of the union's height (whichever is larger), clamped to the picture.
    /// Nil when there are no boxes or nothing of them is inside the picture.
    public static func region(lines: [PixelBox], pictureWidth: Int, pictureHeight: Int) -> PixelRegion? {
        guard !lines.isEmpty, pictureWidth > 0, pictureHeight > 0 else { return nil }
        let left = lines.map(\.x).min()!, top = lines.map(\.y).min()!
        let right = lines.map { $0.x + $0.width }.max()!, bottom = lines.map { $0.y + $0.height }.max()!
        let margin = max(minimumMargin, Int((marginShare * Double(bottom - top)).rounded(.up)))
        let x0 = max(0, left - margin), y0 = max(0, top - margin)
        let x1 = min(pictureWidth, right + margin), y1 = min(pictureHeight, bottom + margin)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The size the cut-out is saved at: its own size, or scaled down to 1600 px wide.
    public static func outputSize(for region: PixelRegion) -> (width: Int, height: Int) {
        guard region.width > maxWidth else { return (region.width, region.height) }
        let scale = Double(maxWidth) / Double(region.width)
        return (maxWidth, max(1, Int((Double(region.height) * scale).rounded())))
    }
}
