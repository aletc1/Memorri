import CoreGraphics
import Foundation

/// Reads a picture in overlapping tiles, each enlarged before it is read. The recogniser works on a limited resolution: a 3440 pixel wide
/// desktop gave 35 lines in one pass, over 450 in tiles, because small text only survives when it is not shrunk, and more again when
/// the tiles are enlarged. Tiles also keep text of windows side by side from being joined into one line.
public struct TiledTextRecogniser: TextRecogniser {
    /// Measured on a 3440 x 1440 display at 1x with a month calendar: tiles of 900 pixels read at twice their size gave 467 lines
    /// and every entry (59 of 59 of one kind), tiles of 1800 pixels at their own size gave 242 lines and half of the entries.
    public static let defaultMaxSide = 900
    public static let defaultOverlap = 120
    public static let defaultMagnify = 2

    private let base: any TextRecogniser
    private let maxSide: Int
    private let overlap: Int
    private let magnify: Int

    /// `magnify` enlarges every tile that many times before it is read (text of 11 pixels on a 1x display is read better at 22),
    /// so `maxSide` is the side of the part of the picture a tile covers. With `magnify` 1, a picture that fits `maxSide` is read once as it is.
    public init(base: any TextRecogniser, maxSide: Int = TiledTextRecogniser.defaultMaxSide, overlap: Int = TiledTextRecogniser.defaultOverlap,
                magnify: Int = TiledTextRecogniser.defaultMagnify) {
        self.base = base; self.maxSide = max(256, maxSide); self.overlap = min(overlap, self.maxSide / 4); self.magnify = max(1, magnify)
    }

    /// The tile enlarged by `factor`, smooth, so letters keep their shape.
    static func enlarged(_ tile: CGImage, by factor: Int) -> CGImage? {
        guard factor > 1 else { return tile }
        let width = tile.width * factor, height = tile.height * factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Starts and lengths along one axis: tiles of at most `maxSide` that overlap by `overlap` and together cover `length`.
    static func spans(length: Int, maxSide: Int, overlap: Int) -> [(start: Int, length: Int)] {
        guard length > maxSide else { return [(0, length)] }
        var spans: [(Int, Int)] = []
        var start = 0
        while true {
            let size = min(maxSide, length - start)
            spans.append((start, size))
            if start + size >= length { break }
            start += maxSide - overlap
        }
        return spans
    }

    public func recognise(_ image: CGImage) async throws -> [RecognisedLine] {
        let columns = Self.spans(length: image.width, maxSide: maxSide, overlap: overlap)
        let rows = Self.spans(length: image.height, maxSide: maxSide, overlap: overlap)
        if columns.count == 1, rows.count == 1, magnify == 1 { return try await base.recognise(image) }

        var found: [(text: String, box: PixelBox, confidence: Double)] = []
        for row in rows {
            for column in columns {
                guard let tile = image.cropping(to: CGRect(x: column.start, y: row.start, width: column.length, height: row.length)) else { continue }
                let seen = Self.enlarged(tile, by: magnify) ?? tile
                let factor = seen.width / max(1, tile.width)
                for line in try await base.recognise(seen) {
                    let box = PixelBox(x: line.box.x / factor + column.start, y: line.box.y / factor + row.start,
                                       width: max(1, line.box.width / factor), height: max(1, line.box.height / factor))
                    found.append((line.text, box, line.confidence))
                }
            }
        }
        return ReadingOrder.sort(LineSplitter.split(Self.removeRepeats(found)))
    }

    /// A line seen in two tiles overlaps itself; the wider one is the one that was not cut by a tile's edge, then the surer one.
    static func removeRepeats(_ lines: [(text: String, box: PixelBox, confidence: Double)]) -> [(text: String, box: PixelBox, confidence: Double)] {
        let ordered = lines.sorted { ($0.box.width, $0.confidence) > ($1.box.width, $1.confidence) }
        var kept: [(text: String, box: PixelBox, confidence: Double)] = []
        for line in ordered where !kept.contains(where: { overlaps($0.box, line.box) }) { kept.append(line) }
        return kept
    }

    /// The boxes share at least half of the smaller one.
    private static func overlaps(_ a: PixelBox, _ b: PixelBox) -> Bool {
        let ix = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x)), iy = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && Double(ix * iy) >= 0.5 * Double(smaller)
    }
}
