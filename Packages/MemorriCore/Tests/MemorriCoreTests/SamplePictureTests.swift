import CoreGraphics
import Foundation
import Testing
@testable import MemorriCore

@Suite struct SamplePictureTests {
    private func pixels(_ image: CGImage) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    @Test(arguments: [1024, 2048, 4096]) func theLongerSideMatchesTheArgument(longEdge: Int) {
        let image = SamplePicture.make(longEdge: longEdge)
        #expect(max(image.width, image.height) == longEdge)
    }

    @Test func thePictureIsNotBlank() {
        let data = pixels(SamplePicture.make(longEdge: 1024))
        let colours = Set(stride(from: 0, to: data.count, by: 4 * 97).map { data[$0 ..< $0 + 3].map { $0 } })
        #expect(colours.count > 1)
    }

    @Test func twoCallsGiveTheSamePixels() {
        #expect(pixels(SamplePicture.make(longEdge: 1024)) == pixels(SamplePicture.make(longEdge: 1024)))
    }

    @Test func theKnownTextsAreListed() {
        #expect(SamplePicture.knownTexts.contains("Team sync"))
        #expect(SamplePicture.knownTexts.contains("10:00"))
    }
}
