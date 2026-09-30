import CoreGraphics
import CoreText
import Foundation

/// A synthetic calendar-like picture with known texts, drawn in code (research R10). It contains
/// nothing from the user's sessions and is the same picture on every call.
public enum SamplePicture {
    public static let knownTexts = ["Mon", "Tue", "Wed", "Thu", "Fri", "Team sync", "10:00"]

    public static func make(longEdge: Int) -> CGImage {
        let width = longEdge, height = longEdge * 9 / 16
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let columns = 5, columnWidth = CGFloat(width) / CGFloat(columns)
        let fontSize = max(14, CGFloat(width) / 42)

        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, white: Bool = false) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let color = white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }

        context.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.setLineWidth(max(1, CGFloat(width) / 1024))
        for column in 0...columns {
            let x = CGFloat(column) * columnWidth
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
            context.strokePath()
        }
        for (index, day) in knownTexts.prefix(columns).enumerated() {
            text(day, x: CGFloat(index) * columnWidth + fontSize, y: CGFloat(height) - fontSize * 2, size: fontSize)
        }

        // One event block on Wednesday.
        let blockX = 2 * columnWidth + columnWidth * 0.06, blockWidth = columnWidth * 0.88
        let blockY = CGFloat(height) * 0.40, blockHeight = CGFloat(height) * 0.22
        context.setFillColor(CGColor(red: 0.12, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: blockX, y: blockY, width: blockWidth, height: blockHeight))
        text("Team sync", x: blockX + fontSize * 0.6, y: blockY + blockHeight - fontSize * 1.6, size: fontSize * 1.2, white: true)
        text("10:00", x: blockX + fontSize * 0.6, y: blockY + blockHeight - fontSize * 3.0, size: fontSize * 1.1, white: true)
        return context.makeImage()!
    }
}
