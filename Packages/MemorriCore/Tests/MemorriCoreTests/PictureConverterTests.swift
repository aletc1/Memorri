import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct PictureConverterTests {
    private func encode(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func size(of data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    private func isJPEG(_ data: Data) -> Bool { data.count > 3 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8 }

    @Test func heicBecomesJPEGOfTheSamePixelSize() throws {
        let heic = try encode(makeTestImage(width: 640, height: 270), type: "public.heic")
        let jpeg = try PictureConverter.jpegData(from: heic)
        #expect(isJPEG(jpeg))
        let (width, height) = try size(of: jpeg)
        #expect(width == 640 && height == 270)
    }

    @Test func pngBecomesJPEG() throws {
        let png = try encode(makeTestImage(width: 300, height: 200), type: "public.png")
        let jpeg = try PictureConverter.jpegData(from: png)
        #expect(isJPEG(jpeg))
        let (width, height) = try size(of: jpeg)
        #expect(width == 300 && height == 200)
    }

    @Test func jpegStaysAJPEGOfTheSameSize() throws {
        let original = try encode(makeTestImage(width: 320, height: 160), type: "public.jpeg")
        let jpeg = try PictureConverter.jpegData(from: original)
        #expect(isJPEG(jpeg))
        let (width, height) = try size(of: jpeg)
        #expect(width == 320 && height == 160)
    }

    @Test func bytesThatAreNotAPictureThrow() {
        #expect(throws: PictureConverterError.self) { try PictureConverter.jpegData(from: Data("not a picture".utf8)) }
        #expect(throws: PictureConverterError.self) { try PictureConverter.jpegData(from: Data()) }
    }
}
