import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import MemorriCore

@Suite struct VisionGeometryTests {
    @Test func aNormalisedBottomLeftBoxBecomesATopLeftPixelBox() {
        // 1000 x 500 picture: x 100...400, and from 20% to 30% of the height counted from the bottom.
        let box = VisionGeometry.pixelBox(x: 0.1, y: 0.2, width: 0.3, height: 0.1, imageWidth: 1000, imageHeight: 500)
        #expect(box == PixelBox(x: 100, y: 350, width: 300, height: 50))
    }

    @Test func theWholePictureIsTheWholePicture() {
        #expect(VisionGeometry.pixelBox(x: 0, y: 0, width: 1, height: 1, imageWidth: 640, imageHeight: 480) == PixelBox(x: 0, y: 0, width: 640, height: 480))
    }

    @Test func aBoxAtTheTopLeftStartsAtZero() {
        let box = VisionGeometry.pixelBox(x: 0, y: 0.9, width: 0.25, height: 0.1, imageWidth: 800, imageHeight: 600)
        #expect(box == PixelBox(x: 0, y: 0, width: 200, height: 60))
    }

    @Test func boxesRoundOutwardAndStayInsideThePicture() {
        let box = VisionGeometry.pixelBox(x: 0.333, y: -0.01, width: 0.7, height: 1.02, imageWidth: 301, imageHeight: 199)
        #expect(box.x == 100 && box.y == 0)
        #expect(box.x + box.width <= 301 && box.y + box.height <= 199)
        #expect(box.width > 0 && box.height > 0)
    }

    /// Runs the real recogniser on a drawn picture: most of the drawn text must come back exactly (SC-003 asks for 95% on the set).
    @Test func readsTheTextOfADrawnPicture() async throws {
        let item = try #require(SyntheticCases.cases.first { $0.name == "calendar-week-outlook-24h-blocks" })
        let source = try #require(CGImageSourceCreateWithData(item.picture as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let lines = try await VisionTextRecogniser().recognise(image)
        #expect(!lines.isEmpty)
        #expect(lines.map(\.n) == Array(1...lines.count))
        let read = Set(lines.map(\.text))
        let drawn = item.expected.lines ?? []
        let exact = drawn.filter { read.contains($0.text) }.count
        #expect(Double(exact) / Double(drawn.count) >= 0.8, "exact \(exact) of \(drawn.count)")
        for line in lines { #expect(line.box.x >= 0 && line.box.y >= 0 && line.box.x + line.box.width <= image.width && line.box.y + line.box.height <= image.height) }
    }

    @Test func aPictureWithoutTextGivesNoLines() async throws {
        let item = try #require(SyntheticCases.cases.first { $0.name == "other-text-free-shapes" })
        let source = try #require(CGImageSourceCreateWithData(item.picture as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(try await VisionTextRecogniser().recognise(image).isEmpty)
    }
}
