import Testing
@testable import MemorriCore

@Suite struct EvidenceGeometryTests {
    private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> PixelBox { PixelBox(x: x, y: y, width: w, height: h) }

    @Test func noLinesGiveNoRegion() {
        #expect(EvidenceGeometry.region(lines: [], pictureWidth: 1000, pictureHeight: 800) == nil)
    }

    @Test func oneLineGetsTheMinimumMarginOnEverySide() {
        let region = EvidenceGeometry.region(lines: [box(100, 200, 300, 40)], pictureWidth: 1000, pictureHeight: 800)
        #expect(region == PixelRegion(x: 76, y: 176, width: 348, height: 88))     // 24 px each side: 15% of 40 is only 6
    }

    @Test func aTallUnionGetsFifteenPercentOfItsHeight() {
        let region = EvidenceGeometry.region(lines: [box(100, 100, 200, 100), box(100, 300, 200, 100)], pictureWidth: 1000, pictureHeight: 800)
        // union 100..400 high = 300; margin max(24, 45) = 45
        #expect(region == PixelRegion(x: 55, y: 55, width: 290, height: 390))
    }

    @Test func theRegionIsClampedToThePictureNotPadded() {
        let region = EvidenceGeometry.region(lines: [box(0, 0, 100, 20), box(900, 780, 100, 20)], pictureWidth: 1000, pictureHeight: 800)
        #expect(region == PixelRegion(x: 0, y: 0, width: 1000, height: 800))
        let corner = EvidenceGeometry.region(lines: [box(980, 790, 20, 10)], pictureWidth: 1000, pictureHeight: 800)
        #expect(corner == PixelRegion(x: 956, y: 766, width: 44, height: 34))
    }

    @Test func everyInputBoxLiesInsideTheRegion() {
        let cases: [[PixelBox]] = [
            [box(5, 5, 10, 10)], [box(3000, 100, 800, 30), box(200, 140, 500, 30)], [box(10, 10, 1980, 1000)],
            [box(0, 0, 2000, 40)], [box(1990, 1990, 10, 10), box(0, 0, 10, 10)],
        ]
        for lines in cases {
            let region = EvidenceGeometry.region(lines: lines, pictureWidth: 4000, pictureHeight: 2000)
            for line in lines {
                let r = try! #require(region)
                #expect(r.x <= line.x && r.y <= line.y && r.x + r.width >= line.x + line.width && r.y + r.height >= line.y + line.height)
            }
        }
    }

    @Test func aBoxPartlyOutsideThePictureIsClampedNotRejected() {
        let region = EvidenceGeometry.region(lines: [box(-10, -5, 50, 20)], pictureWidth: 100, pictureHeight: 100)
        #expect(region == PixelRegion(x: 0, y: 0, width: 64, height: 39))
    }

    @Test func outputSizeKeepsSmallRegionsAndScalesWideOnesDown() {
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 1600, height: 400)) == (1600, 400))
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 800, height: 300)) == (800, 300))
        let wide = EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 3200, height: 400))
        #expect(wide == (1600, 200))
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 4000, height: 1)).height == 1)
    }
}
