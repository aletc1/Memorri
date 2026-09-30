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

    /// The most common colour inside the title's box: the text sits on its block's fill (or on the page), and glyphs are the minority.
    private static func fillColour(around title: PixelBox, in pixels: Pixels) -> (Int, Int, Int) {
        var votes: [[Int]: (count: Int, colour: (Int, Int, Int))] = [:]
        for y in stride(from: title.y, to: title.y + title.height, by: 2) {
            for x in stride(from: title.x, to: title.x + title.width, by: 2) {
                let c = pixels.colour(x, y)
                let key = [c.0 / 12, c.1 / 12, c.2 / 12]
                votes[key] = ((votes[key]?.count ?? 0) + 1, votes[key]?.colour ?? c)
            }
        }
        return votes.values.max { $0.count < $1.count }?.colour ?? pixels.colour(title.x, title.y)
    }

    /// The vertical extent in pixels of the block around a title, or nil when it is not clearly a block. A filled block: the
    /// colour around the title differs from the page, the block is at least three title heights wide and no wider than a column,
    /// and taller than the title (without the width checks a start on a grid line once gave a 540-minute block). An outlined
    /// block, which has the page's own colour inside: a border line above and another below the title, each no longer than a column
    /// (a longer line is a grid line).
    public static func blockHeight(around title: PixelBox, in image: CGImage, columnWidth: Int) -> Int? {
        guard let pixels = Pixels(image), title.height > 0 else { return nil }
        let w = pixels.width, h = pixels.height
        let seedY = title.y + title.height / 2
        guard seedY > 1, seedY < h - 2 else { return nil }
        let background = pixels.colour(2, seedY)
        let fill = fillColour(around: title, in: pixels)
        let result: Int?
        if distance(fill, background) >= 40 {
            result = filledHeight(title: title, pixels: pixels, fill: fill, background: background, columnWidth: columnWidth)
        } else {
            result = outlinedHeight(title: title, pixels: pixels, background: background, columnWidth: columnWidth)
        }
        guard let height = result, height >= title.height, height < h, w > 0 else { return nil }
        return height
    }

    private static func filledHeight(title: PixelBox, pixels: Pixels, fill: (Int, Int, Int), background: (Int, Int, Int), columnWidth: Int) -> Int? {
        let w = pixels.width, h = pixels.height
        let seedY = title.y + title.height / 2
        let tolerance = min(95, max(24, distance(fill, background) / 2))
        // A column just beside the text that is inside the block.
        guard let x = [title.x - 3, title.x + title.width + 3, title.x + title.width + 12].first(where: { distance(pixels.colour($0, seedY), fill) < tolerance }) else { return nil }
        var up = seedY, down = seedY
        while up > 1, distance(pixels.colour(x, up - 1), fill) < tolerance { up -= 1 }
        while down < h - 2, distance(pixels.colour(x, down + 1), fill) < tolerance { down += 1 }
        // A row just inside the block's top edge is free of text.
        let rowY = min(down, up + 2)
        var left = x, right = x
        while left > 1, distance(pixels.colour(left - 1, rowY), fill) < tolerance { left -= 1 }
        while right < w - 2, distance(pixels.colour(right + 1, rowY), fill) < tolerance { right += 1 }
        let width = right - left + 1
        if width < title.height * 3 || width > columnWidth { return nil }
        return down - up + 1
    }

    private static func outlinedHeight(title: PixelBox, pixels: Pixels, background: (Int, Int, Int), columnWidth: Int) -> Int? {
        let h = pixels.height
        let xs = Array(stride(from: title.x, through: title.x + title.width, by: 2))
        func isLine(at y: Int) -> Bool {
            let hits = xs.filter { distance(pixels.colour($0, y), background) > 60 }.count
            return hits * 10 >= xs.count * 8
        }
        func lineLength(at y: Int) -> Int {
            let start = title.x + title.width / 2
            var left = start, right = start
            while left > 1, distance(pixels.colour(left - 1, y), background) > 60 { left -= 1 }
            while right < pixels.width - 2, distance(pixels.colour(right + 1, y), background) > 60 { right += 1 }
            return right - left + 1
        }
        let reach = min(h, title.height * 40)
        var top: Int?, bottom: Int?
        for y in stride(from: title.y - 1, through: max(1, title.y - reach), by: -1) where isLine(at: y) { top = y; break }
        for y in (title.y + title.height)..<min(h - 1, title.y + title.height + reach) where isLine(at: y) { bottom = y; break }
        guard let top, let bottom, bottom > top else { return nil }
        for y in [top, bottom] {
            let length = lineLength(at: y)
            if length < title.height * 3 || length > Int(Double(columnWidth) * 1.05) { return nil }
        }
        return bottom - top + 1
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
