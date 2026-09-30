import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct ImageEncodingTests {
    private let encoder = HEICImageEncoder()

    private func decode(_ picture: EncodedPicture) -> (type: String?, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(picture.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (CGImageSourceGetType(source) as String?, image.width, image.height)
    }

    @Test func fullResolutionKeepsThePixelSizeAndIsHEIC() throws {
        let picture = try encoder.encodeFullResolution(makeTestImage(width: 3440, height: 1440))
        #expect(picture.width == 3440 && picture.height == 1440)
        let decoded = try #require(decode(picture))
        #expect(decoded.type == "public.heic")
        #expect(decoded.width == 3440 && decoded.height == 1440)
    }

    @Test func analysisCopyOfALandscapeImageHasTheConfiguredLongerSide() throws {
        let picture = try encoder.encodeAnalysisCopy(makeTestImage(width: 3440, height: 1440), longEdge: 2048)
        #expect(picture.width == 2048)
        #expect(abs(picture.height - 857) <= 1)
        let decoded = try #require(decode(picture))
        #expect(decoded.width == picture.width && decoded.height == picture.height)
    }

    @Test func analysisCopyOfAPortraitImageHasTheConfiguredLongerSide() throws {
        let picture = try encoder.encodeAnalysisCopy(makeTestImage(width: 1440, height: 3440), longEdge: 2048)
        #expect(picture.height == 2048)
        #expect(abs(picture.width - 857) <= 1)
    }

    @Test func analysisCopyIsNeverEnlarged() throws {
        let picture = try encoder.encodeAnalysisCopy(makeTestImage(width: 1000, height: 600), longEdge: 2048)
        #expect(picture.width == 1000 && picture.height == 600)
    }

    @Test func analysisCopyFollowsADifferentConfiguredSize() throws {
        let picture = try encoder.encodeAnalysisCopy(makeTestImage(width: 3440, height: 1440), longEdge: 1024)
        #expect(picture.width == 1024)
    }

    @Test func qualityLevelsAreNamedAndHigh() {
        #expect(StorageQuality.fullResolution == 0.9)
        #expect(StorageQuality.analysisCopy == 0.9)
    }
}
