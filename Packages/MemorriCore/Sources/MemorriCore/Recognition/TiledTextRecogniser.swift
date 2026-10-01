import CoreGraphics
import Foundation

/// Reads a large picture in overlapping tiles. The recogniser works on a limited resolution: a 3440 pixel wide desktop gave 35 lines,
/// where the same desktop read in two halves gave over 450, because small text only survives when the picture is not shrunk. Tiles also
/// keep text of windows side by side from being joined into one line. A picture that fits is read once as it is.
public struct TiledTextRecogniser: TextRecogniser {
    public static let defaultMaxSide = 1800
    public static let defaultOverlap = 160

    private let base: any TextRecogniser
    private let maxSide: Int
    private let overlap: Int

    public init(base: any TextRecogniser, maxSide: Int = TiledTextRecogniser.defaultMaxSide, overlap: Int = TiledTextRecogniser.defaultOverlap) {
        self.base = base; self.maxSide = max(256, maxSide); self.overlap = min(overlap, self.maxSide / 4)
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
        if columns.count == 1, rows.count == 1 { return try await base.recognise(image) }

        var found: [(text: String, box: PixelBox, confidence: Double)] = []
        for row in rows {
            for column in columns {
                guard let tile = image.cropping(to: CGRect(x: column.start, y: row.start, width: column.length, height: row.length)) else { continue }
                for line in try await base.recognise(tile) {
                    let box = PixelBox(x: line.box.x + column.start, y: line.box.y + row.start, width: line.box.width, height: line.box.height)
                    found.append((line.text, box, line.confidence))
                }
            }
        }
        return ReadingOrder.sort(Self.removeRepeats(found))
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
