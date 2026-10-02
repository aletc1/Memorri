import Testing
@testable import MemorriCore

@Suite struct EvidenceGeometryTests {
    private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> PixelBox { PixelBox(x: x, y: y, width: w, height: h) }

    @Test func noLinesGiveNoRegion() {
        #expect(EvidenceGeometry.region(lines: [], pictureWidth: 1000, pictureHeight: 800) == nil)
    }

    @Test func oneLineGetsHalfThePicturesWidthAndAThirdOfItsHeightAroundIt() {
        let region = EvidenceGeometry.region(lines: [box(100, 200, 300, 40)], pictureWidth: 1000, pictureHeight: 800)
        #expect(region == PixelRegion(x: 0, y: 80, width: 500, height: 280))      // 500 x 280 centred on the line, the left edge stops it
        let middle = EvidenceGeometry.region(lines: [box(450, 380, 100, 40)], pictureWidth: 1000, pictureHeight: 800)
        #expect(middle == PixelRegion(x: 250, y: 260, width: 500, height: 280))
    }

    @Test func aSmallPictureKeepsTheMarginAroundALine() {
        let region = EvidenceGeometry.region(lines: [box(100, 200, 300, 40)], pictureWidth: 600, pictureHeight: 300)
        // the context (300 x 105) is narrower than the line with its margin (348), so the margin wins on width and the context on height
        #expect(region == PixelRegion(x: 76, y: 168, width: 348, height: 105))
    }

    @Test func aTallUnionGetsFifteenPercentOfItsHeight() {
        let region = EvidenceGeometry.region(lines: [box(100, 100, 200, 100), box(100, 300, 200, 100)], pictureWidth: 1000, pictureHeight: 800)
        // union 100..400 high = 300; margin max(24, 45) = 45: 390 high is more than a third of 800, the width is widened to half of 1000
        #expect(region == PixelRegion(x: 0, y: 55, width: 500, height: 390))
    }

    @Test func theRegionIsClampedToThePictureNotPadded() {
        let region = EvidenceGeometry.region(lines: [box(0, 0, 100, 20), box(900, 780, 100, 20)], pictureWidth: 1000, pictureHeight: 800)
        #expect(region == PixelRegion(x: 0, y: 0, width: 1000, height: 800))
        let corner = EvidenceGeometry.region(lines: [box(980, 790, 20, 10)], pictureWidth: 1000, pictureHeight: 800)
        #expect(corner == PixelRegion(x: 500, y: 520, width: 500, height: 280))
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
        #expect(region == PixelRegion(x: 0, y: 0, width: 98, height: 68))
    }

    @Test func outputSizeKeepsSmallRegionsAndScalesWideOnesDown() {
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 1600, height: 400)) == (1600, 400))
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 800, height: 300)) == (800, 300))
        let wide = EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 3200, height: 400))
        #expect(wide == (1600, 200))
        #expect(EvidenceGeometry.outputSize(for: PixelRegion(x: 0, y: 0, width: 4000, height: 1)).height == 1)
    }

    // MARK: a finding with a window (version 3)

    @Test func theVersionIsThreeForCutOutsOfWindows() {
        #expect(EvidenceGeometry.version == 3)
    }

    @Test func aWindowNotLargerThan1400By800IsCutOutWhole() {
        let region = EvidenceGeometry.region(lines: [box(500, 300, 100, 20)], window: box(200, 100, 1400, 800), pictureWidth: 3000, pictureHeight: 2000)
        #expect(region == PixelRegion(x: 200, y: 100, width: 1400, height: 800))
    }

    @Test func aWindowPartlyOffThePictureIsClippedToIt() {
        let region = EvidenceGeometry.region(lines: [box(20, 30, 100, 20)], window: box(-100, -50, 900, 600), pictureWidth: 2000, pictureHeight: 1200)
        #expect(region == PixelRegion(x: 0, y: 0, width: 800, height: 550))
    }

    @Test func aWindowWithNothingInsideThePictureGivesNoRegion() {
        #expect(EvidenceGeometry.region(lines: [box(0, 0, 10, 10)], window: box(2100, 0, 300, 300), pictureWidth: 2000, pictureHeight: 1200) == nil)
    }

    @Test func aLargerWindowGivesA1400By800RectangleAroundTheCitedLines() {
        let region = EvidenceGeometry.region(lines: [box(1500, 900, 200, 30)], window: box(0, 0, 3000, 1800), pictureWidth: 3000, pictureHeight: 1800)
        #expect(region?.width == 1400 && region?.height == 800)
        let r = region!
        #expect(r.x <= 1500 && r.x + r.width >= 1700 && r.y <= 900 && r.y + r.height >= 930)
        #expect(r == PixelRegion(x: 900, y: 515, width: 1400, height: 800))   // centred on the line's middle (1600, 915)
    }

    @Test func theRectangleIsShiftedToStayInsideTheFrame() {
        let window = box(1000, 500, 2000, 1200)
        let corner = EvidenceGeometry.region(lines: [box(1010, 510, 100, 20)], window: window, pictureWidth: 3000, pictureHeight: 2000)!
        #expect(corner == PixelRegion(x: 1000, y: 500, width: 1400, height: 800))
        let far = EvidenceGeometry.region(lines: [box(2900, 1650, 90, 20)], window: window, pictureWidth: 3000, pictureHeight: 2000)!
        #expect(far == PixelRegion(x: 1600, y: 900, width: 1400, height: 800))
    }

    @Test func aWindowWiderThanTallOnlyLimitsTheAxisThatIsLarge() {
        let region = EvidenceGeometry.region(lines: [box(900, 100, 100, 20)], window: box(0, 0, 2400, 600), pictureWidth: 3000, pictureHeight: 2000)!
        #expect(region.width == 1400 && region.height == 600 && region.y == 0)
    }

    @Test func theRegionNeverLeavesTheFrameEvenForLinesOutsideIt() {
        let window = box(100, 100, 2000, 1500)
        for line in [box(0, 0, 50, 20), box(2900, 1900, 50, 20), box(100, 100, 2000, 1500)] {
            let r = EvidenceGeometry.region(lines: [line], window: window, pictureWidth: 3000, pictureHeight: 2000)!
            #expect(r.x >= 100 && r.y >= 100 && r.x + r.width <= 2100 && r.y + r.height <= 1600)
        }
    }

    @Test func linesTallerThanTheRectangleKeepTheirStartInView() {
        let r = EvidenceGeometry.region(lines: [box(500, 200, 100, 20), box(500, 1400, 100, 20)], window: box(0, 0, 3000, 1800), pictureWidth: 3000, pictureHeight: 1800)!
        #expect(r.y <= 200 && r.height == 800)
    }
}
