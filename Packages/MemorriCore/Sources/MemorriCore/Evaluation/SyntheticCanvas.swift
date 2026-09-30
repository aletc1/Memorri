import CoreGraphics
import CoreText
import Foundation
import ImageIO

struct RGB: Sendable {
    let r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
    }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A picture drawn in code, in top-left coordinates. Everything it draws is deterministic, and every text it draws is
/// remembered with the box it covers, so a synthetic case knows exactly what a reader should find.
final class SyntheticCanvas {
    let width: Int
    let height: Int
    private let context: CGContext
    private(set) var lines: [ExpectedLine] = []

    init(width: Int, height: Int, background: RGB) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        fill(CGRect(x: 0, y: 0, width: width, height: height), background)
    }

    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    func fill(_ rect: CGRect, _ color: RGB) {
        context.setFillColor(color.cgColor)
        context.fill(flipped(rect))
    }

    func fillRounded(_ rect: CGRect, radius: Double, _ color: RGB) {
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: flipped(rect), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func fillCircle(center: CGPoint, radius: Double, _ color: RGB) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: flipped(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)))
    }

    func stroke(_ rect: CGRect, _ color: RGB, width lineWidth: Double = 1) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(flipped(rect))
    }

    func line(from a: CGPoint, to b: CGPoint, _ color: RGB, width lineWidth: Double = 1) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.move(to: CGPoint(x: a.x, y: Double(height) - a.y))
        context.addLine(to: CGPoint(x: b.x, y: Double(height) - b.y))
        context.strokePath()
    }

    private func font(_ size: Double, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func ctLine(_ text: String, size: Double, color: RGB, bold: Bool) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func textWidth(_ text: String, size: Double, bold: Bool = false) -> Double {
        CTLineGetTypographicBounds(ctLine(text, size: size, color: RGB(0), bold: bold), nil, nil, nil)
    }

    /// Draws `text` with the top of its line box at `y`. Returns the box it covers (and remembers it when `record`).
    @discardableResult
    func text(_ text: String, x: Double, y: Double, size: Double, color: RGB, bold: Bool = false, record: Bool = true) -> CGRect {
        let line = ctLine(text, size: size, color: color, bold: bold)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: x, y: Double(height) - (y + Double(ascent)))
        CTLineDraw(line, context)
        let box = CGRect(x: x, y: y, width: w, height: Double(ascent + descent))
        if record {
            lines.append(ExpectedLine(text: text, box: [Int(box.minX.rounded(.down)), Int(box.minY.rounded(.down)),
                                                        Int(box.width.rounded(.up)), Int(box.height.rounded(.up))]))
        }
        return box
    }

    func pngData() throws -> Data {
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

/// One drawn case, ready to be written as a golden case.
struct SyntheticCase: Sendable {
    let name: String
    let meta: GoldenMeta
    let expected: GoldenExpected
    let picture: Data
    /// Situations this case covers, checked by the tests (`relative-date`, `block-90`, `look-outlook`, ...).
    let features: Set<String>

    var golden: GoldenCase { GoldenCase(name: name, folder: URL(fileURLWithPath: "/"), meta: meta, expected: expected) }
}

enum SyntheticTime {
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

/// Colours shared by the drawings.
struct Palette: Sendable {
    let background: RGB, panel: RGB, bar: RGB, barText: RGB, text: RGB, muted: RGB, line: RGB, accent: RGB, dark: Bool

    static let light = Palette(background: RGB(0xFFFFFF), panel: RGB(0xF3F3F3), bar: RGB(0x0F6CBD), barText: RGB(0xFFFFFF),
                               text: RGB(0x1F1F1F), muted: RGB(0x6B6B6B), line: RGB(0xD0D0D0), accent: RGB(0x0F6CBD), dark: false)
    static let mac = Palette(background: RGB(0xFFFFFF), panel: RGB(0xEDEDED), bar: RGB(0xDCDCDC), barText: RGB(0x333333),
                             text: RGB(0x1C1C1C), muted: RGB(0x707070), line: RGB(0xD6D6D6), accent: RGB(0x0A84FF), dark: false)
    static let dark = Palette(background: RGB(0x1E1E1E), panel: RGB(0x2B2B2B), bar: RGB(0x464775), barText: RGB(0xFFFFFF),
                              text: RGB(0xF0F0F0), muted: RGB(0xA0A0A0), line: RGB(0x4A4A4A), accent: RGB(0x8B8CC7), dark: true)
}
