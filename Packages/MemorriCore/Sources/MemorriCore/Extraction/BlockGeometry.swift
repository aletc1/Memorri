import CoreGraphics
import Foundation

/// How many pixels an hour takes on a calendar's hour scale.
public struct HourScale: Sendable, Equatable {
    public let pixelsPerHour: Double

    public init(pixelsPerHour: Double) { self.pixelsPerHour = pixelsPerHour }

    public func minutes(forPixels pixels: Double) -> Double { pixels / pixelsPerHour * 60 }
}

/// Reads how long a calendar block lasts from its height on the picture (research R7, spike S3). It only ever gives a value
/// it can vouch for; anything unclear gives nil, and the caller falls back to the one-hour default.
public enum BlockGeometry {
    public static let minimumMinutes = 30
    public static let maximumMinutes = 720

    // MARK: Hour scale

    private static let clockLabel = try! NSRegularExpression(pattern: #"^(\d{1,2})(?::00)?\s?(am|pm)?$"#, options: [.caseInsensitive])

    /// The hour of a clock label such as `9 AM`, `09:00` or `5 PM` (0 to 24), or nil for any other text.
    private static func hour(of text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let match = clockLabel.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let hourRange = Range(match.range(at: 1), in: trimmed), let value = Int(trimmed[hourRange]) else { return nil }
        if let meridiemRange = Range(match.range(at: 2), in: trimmed) {
            guard (1...12).contains(value) else { return nil }
            return value % 12 + (trimmed[meridiemRange].lowercased() == "pm" ? 12 : 0)
        }
        return (0...24).contains(value) ? value : nil
    }

    /// Fits the clock labels of one narrow column to a line: hours against the vertical centre of each label. Nil with fewer
    /// than two labels, labels that do not grow with their hour, or labels that do not sit on a line.
    public static func hourScale(lines: [RecognisedLine]) -> HourScale? {
        let candidates = lines.compactMap { line in hour(of: line.text).map { (line: line, hour: $0) } }
        guard candidates.count >= 2 else { return nil }
        let heights = candidates.map(\.line.box.height).sorted()
        let tolerance = max(40, 2 * heights[heights.count / 2])
        // The largest group of labels with about the same left edge.
        let groups = candidates.map { centre in candidates.filter { abs($0.line.box.x - centre.line.box.x) <= tolerance } }
        guard let group = groups.max(by: { $0.count < $1.count }), group.count >= 2 else { return nil }
        let column = group.sorted { $0.line.box.y < $1.line.box.y }
        for (a, b) in zip(column, column.dropFirst()) where b.hour <= a.hour { return nil }

        let points = column.map { (hour: Double($0.hour), y: $0.line.box.midY) }
        let n = Double(points.count)
        let sumH = points.map(\.hour).reduce(0, +), sumY = points.map(\.y).reduce(0, +)
        let sumHY = points.map { $0.hour * $0.y }.reduce(0, +), sumHH = points.map { $0.hour * $0.hour }.reduce(0, +)
        let denominator = n * sumHH - sumH * sumH
        guard denominator != 0 else { return nil }
        let slope = (n * sumHY - sumH * sumY) / denominator
        let intercept = (sumY - slope * sumH) / n
        guard slope > 10, points.allSatisfy({ abs($0.y - (intercept + slope * $0.hour)) <= 0.2 * slope }) else { return nil }
        return HourScale(pixelsPerHour: slope)
    }

    // MARK: Block height

    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            width = w; height = h
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            data = buffer
        }

        func colour(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let cx = min(max(0, x), width - 1), cy = min(max(0, y), height - 1)
            let i = (cy * width + cx) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }

    /// The vertical extent in pixels of the coloured block around a title, or nil when it is not clearly a block: the colour
    /// just left of the title and just above it must agree, the block must be at least three title heights wide and no wider than a
    /// column, and taller than the title. (Without these checks a start on a grid line once gave a 540-minute block.)
    public static func blockHeight(around title: PixelBox, in image: CGImage, columnWidth: Int) -> Int? {
        guard let pixels = Pixels(image), title.height > 0 else { return nil }
        let w = pixels.width, h = pixels.height
        let seedY = title.y + title.height / 2
        guard seedY > 1, seedY < h - 2 else { return nil }
        var x = max(2, title.x - 4)
        let background = pixels.colour(2, seedY)
        var seed = pixels.colour(x, seedY)
        let above = pixels.colour(title.x + title.width / 2, max(1, title.y - 4))
        var tolerance = 95
        let outlined = distance(seed, background) < 40
        if outlined {
            // An outlined block has the page's colour inside: look for its border to the left of the title.
            guard let border = (1...60).first(where: { distance(pixels.colour(max(0, x - $0), seedY), background) > 120 }) else { return nil }
            x = max(0, x - border)
            seed = pixels.colour(x, seedY)
        } else {
            if distance(seed, above) > 140 { return nil }
            tolerance = min(95, max(24, distance(seed, background) / 2))
        }

        var up = seedY, down = seedY
        while up > 1, distance(pixels.colour(x, up - 1), seed) < tolerance { up -= 1 }
        while down < h - 2, distance(pixels.colour(x, down + 1), seed) < tolerance { down += 1 }

        if !outlined {
            let rowY = max(1, title.y - 4)
            var left = x, right = x
            while left > 1, distance(pixels.colour(left - 1, rowY), seed) < tolerance { left -= 1 }
            while right < w - 2, distance(pixels.colour(right + 1, rowY), seed) < tolerance { right += 1 }
            let width = right - left + 1
            if width < title.height * 3 || width > columnWidth { return nil }
        }
        let height = down - up + 1
        return height < Int(Double(title.height) * 1.2) ? nil : height
    }

    // MARK: Duration

    /// Minutes for a height in pixels, rounded to 15 and kept between 30 minutes and 12 hours.
    static func roundedMinutes(forPixels pixels: Double, scale: HourScale) -> Int {
        let rounded = Int((scale.minutes(forPixels: pixels) / 15).rounded()) * 15
        return min(max(rounded, minimumMinutes), maximumMinutes)
    }

    /// The length in minutes of the block a title sits in, or nil when the picture has no usable hour scale or block.
    public static func duration(titleBox: PixelBox, lines: [RecognisedLine], image: CGImage, columnWidth: Int) -> Int? {
        guard let scale = hourScale(lines: lines), let height = blockHeight(around: titleBox, in: image, columnWidth: columnWidth) else { return nil }
        return roundedMinutes(forPixels: Double(height), scale: scale)
    }
}
