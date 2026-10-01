import CoreGraphics
import Foundation
import ImageIO

public enum PictureConverterError: Error, Sendable, Equatable {
    case notAPicture
    case cannotEncode
}

/// The server does not read HEIC (spike S2), so stored analysis copies are sent as JPEG.
public enum PictureConverter {
    public static let jpegQuality = 0.9

    public static func jpegData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PictureConverterError.notAPicture }
        return try jpegData(from: image)
    }

    /// JPEG whose longer side is at most `longEdge`; a picture that is already smaller is not enlarged.
    public static func jpegData(from data: Data, longEdge: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PictureConverterError.notAPicture }
        let longest = max(image.width, image.height)
        guard longest > longEdge, longEdge > 0 else { return try jpegData(from: image) }
        let scale = Double(longEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PictureConverterError.cannotEncode }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw PictureConverterError.cannotEncode }
        return try jpegData(from: scaled)
    }

    public static func jpegData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw PictureConverterError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PictureConverterError.cannotEncode }
        return output as Data
    }
}
