import CoreGraphics
import Foundation
import ImageIO

/// Named HEIC quality levels (FR-004). One place to raise them later.
public enum StorageQuality {
    public static let fullResolution: Double = 0.9
    public static let analysisCopy: Double = 0.9
}

public struct EncodedPicture: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

public enum ImageEncodingError: Error, Sendable, Equatable {
    case cannotScale
    case cannotEncode
}

public protocol ImageEncoding: Sendable {
    /// HEIC at the picture's own pixel size.
    func encodeFullResolution(_ image: CGImage) throws -> EncodedPicture
    /// HEIC whose longer side is `min(longEdge, original longer side)`; never enlarged.
    func encodeAnalysisCopy(_ image: CGImage, longEdge: Int) throws -> EncodedPicture
}

/// HEIC encoding with ImageIO.
public struct HEICImageEncoder: ImageEncoding {
    public init() {}

    public func encodeFullResolution(_ image: CGImage) throws -> EncodedPicture {
        try encode(image, quality: StorageQuality.fullResolution)
    }

    public func encodeAnalysisCopy(_ image: CGImage, longEdge: Int) throws -> EncodedPicture {
        let longer = max(image.width, image.height)
        guard longer > longEdge else {
            return try encode(image, quality: StorageQuality.analysisCopy)
        }
        let factor = Double(longEdge) / Double(longer)
        let width = image.width >= image.height ? longEdge : max(1, Int((Double(image.width) * factor).rounded()))
        let height = image.height > image.width ? longEdge : max(1, Int((Double(image.height) * factor).rounded()))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageEncodingError.cannotScale }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        guard let scaled = context.makeImage() else { throw ImageEncodingError.cannotScale }
        return try encode(scaled, quality: StorageQuality.analysisCopy)
    }

    private func encode(_ image: CGImage, quality: Double) throws -> EncodedPicture {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            throw ImageEncodingError.cannotEncode
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.cannotEncode }
        return EncodedPicture(data: data as Data, width: image.width, height: image.height)
    }
}
