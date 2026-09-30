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
