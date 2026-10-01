import Foundation

/// A rectangle in whole pixels of one picture, with the origin at its top-left corner.
public struct PixelBox: Sendable, Equatable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { Double(x) + Double(width) / 2 }
    public var midY: Double { Double(y) + Double(height) / 2 }
}
