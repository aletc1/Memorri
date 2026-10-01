import CoreGraphics
import Foundation
import Testing
@testable import MemorriCore

/// A recogniser that answers per crop: it is told the crop's size and returns lines in the crop's own coordinates.
private final class FakeCropRecogniser: TextRecogniser, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sizes: [(Int, Int)] = []
    let answer: @Sendable (Int, Int, Int) -> [RecognisedLine]      // call index, width, height
    init(answer: @escaping @Sendable (Int, Int, Int) -> [RecognisedLine]) { self.answer = answer }
    func recognise(_ image: CGImage) async throws -> [RecognisedLine] {
        let index = lock.withLock { sizes.append((image.width, image.height)); return sizes.count - 1 }
        return answer(index, image.width, image.height)
    }
}

private func line(_ text: String, x: Int, y: Int = 100, w: Int = 100, h: Int = 18) -> RecognisedLine {
    RecognisedLine(n: 0, text: text, box: PixelBox(x: x, y: y, width: w, height: h), confidence: 0.9)
}

@Suite struct TiledTextRecogniserTests {
    @Test func aPictureThatFitsIsReadOnceAsItIs() async throws {
        let base = FakeCropRecogniser { _, _, _ in [line("a", x: 10), line("b", x: 500)] }
        let lines = try await TiledTextRecogniser(base: base).recognise(makeTestImage(width: 1600, height: 1000))
        #expect(base.sizes.count == 1 && base.sizes[0] == (1600, 1000))
        #expect(lines.map(\.text) == ["a", "b"])
    }

    @Test func aWidePictureIsReadInOverlappingTilesNoWiderThanTheLimit() async throws {
        let base = FakeCropRecogniser { _, _, _ in [] }
        _ = try await TiledTextRecogniser(base: base, maxSide: 1800, overlap: 160).recognise(makeTestImage(width: 3440, height: 1440))
        #expect(base.sizes.count == 2)
        #expect(base.sizes.allSatisfy { $0.0 <= 1800 && $0.1 == 1440 })
        #expect(base.sizes[0].0 + base.sizes[1].0 >= 3440 + 160)           // the tiles overlap by at least the margin
    }

    @Test func aTallAndWidePictureIsTiledBothWays() async throws {
        let base = FakeCropRecogniser { _, _, _ in [] }
        _ = try await TiledTextRecogniser(base: base, maxSide: 1800, overlap: 160).recognise(makeTestImage(width: 3440, height: 2400))
        #expect(base.sizes.count == 4)
    }

    @Test func linesAreMovedToTheirPlaceInTheWholePicture() async throws {
        // Both tiles see their own first line at x = 50 in tile coordinates; the second tile starts at 1800 - 160 = 1640.
        let base = FakeCropRecogniser { index, _, _ in [line("tile\(index)", x: 50, y: 200)] }
        let lines = try await TiledTextRecogniser(base: base, maxSide: 1800, overlap: 160).recognise(makeTestImage(width: 3440, height: 1000))
        #expect(lines.map(\.text) == ["tile0", "tile1"])
        #expect(lines[0].box.x == 50 && lines[1].box.x == 1640 + 50)
    }

    @Test func aLineSeenTwiceInTheOverlapIsKeptOnceAndTheWholeOneBeatsTheCutOne() async throws {
        // The first tile ends mid-word (narrow); the second holds the whole line.
        let base = FakeCropRecogniser { index, _, _ in
            index == 0 ? [line("Daily stan", x: 1700, y: 300, w: 100)] : [line("Daily standup", x: 1700 - 1640, y: 300, w: 190)]
        }
        let lines = try await TiledTextRecogniser(base: base, maxSide: 1800, overlap: 160).recognise(makeTestImage(width: 3440, height: 1000))
        #expect(lines.map(\.text) == ["Daily standup"])
    }

    @Test func differentLinesAtTheSamePlaceInDifferentRowsAreBothKept() async throws {
        let base = FakeCropRecogniser { _, _, _ in [line("one", x: 100, y: 100), line("two", x: 100, y: 130)] }
        let lines = try await TiledTextRecogniser(base: base).recognise(makeTestImage(width: 800, height: 600))
        #expect(lines.map(\.text) == ["one", "two"])
    }

    @Test func aFailureOfOneTileFailsTheRead() async {
        struct Boom: Error {}
        final class Failing: TextRecogniser, @unchecked Sendable { func recognise(_ image: CGImage) async throws -> [RecognisedLine] { throw Boom() } }
        await #expect(throws: Boom.self) { _ = try await TiledTextRecogniser(base: Failing()).recognise(makeTestImage(width: 3000, height: 1000)) }
    }
}
