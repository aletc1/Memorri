import Testing
@testable import MemorriCore

@Suite struct CaptureOutlineGeometryTests {
    private let main = DesktopRect(x: 0, y: 0, width: 3440, height: 1440)
    private let right = DesktopRect(x: 3440, y: 0, width: 3440, height: 1440)
    private let left = DesktopRect(x: -3440, y: 0, width: 3440, height: 1440)

    @Test func aWindowInsideOneDisplayGivesOneSegmentInThatDisplaysOwnCoordinates() {
        let segments = CaptureOutlineGeometry.segments(for: DesktopRect(x: 100, y: 50, width: 600, height: 400), displays: [main, right, left])
        #expect(segments == [OutlineSegment(displayIndex: 0, rect: DesktopRect(x: 100, y: 50, width: 600, height: 400))])
    }

    @Test func aWindowOnASecondDisplayIsMeasuredFromThatDisplaysCorner() {
        let segments = CaptureOutlineGeometry.segments(for: DesktopRect(x: 3640, y: 100, width: 500, height: 300), displays: [main, right])
        #expect(segments == [OutlineSegment(displayIndex: 1, rect: DesktopRect(x: 200, y: 100, width: 500, height: 300))])
    }

    @Test func aWindowAcrossTwoDisplaysGivesTwoSegmentsThatTogetherCoverIt() {
        let frame = DesktopRect(x: 3140, y: 100, width: 700, height: 400)
        let segments = CaptureOutlineGeometry.segments(for: frame, displays: [main, right, left])
        #expect(segments == [OutlineSegment(displayIndex: 0, rect: DesktopRect(x: 3140, y: 100, width: 300, height: 400)),
                             OutlineSegment(displayIndex: 1, rect: DesktopRect(x: 0, y: 100, width: 400, height: 400))])
        #expect(segments.reduce(0) { $0 + $1.rect.width * $1.rect.height } == frame.width * frame.height)
    }

    @Test func aWindowLeftOfTheMainDisplayUsesNegativeDesktopCoordinates() {
        let segments = CaptureOutlineGeometry.segments(for: DesktopRect(x: -3000, y: 20, width: 400, height: 300), displays: [main, left])
        #expect(segments == [OutlineSegment(displayIndex: 1, rect: DesktopRect(x: 440, y: 20, width: 400, height: 300))])
    }

    @Test func thePartOffEveryScreenIsLeftOut() {
        let segments = CaptureOutlineGeometry.segments(for: DesktopRect(x: -100, y: -50, width: 600, height: 400), displays: [main])
        #expect(segments == [OutlineSegment(displayIndex: 0, rect: DesktopRect(x: 0, y: 0, width: 500, height: 350))])
    }

    @Test func aWindowOnNoDisplayGivesNoSegment() {
        #expect(CaptureOutlineGeometry.segments(for: DesktopRect(x: 9000, y: 9000, width: 100, height: 100), displays: [main, right]).isEmpty)
        #expect(CaptureOutlineGeometry.segments(for: DesktopRect(x: 0, y: 0, width: 100, height: 100), displays: []).isEmpty)
    }

    @Test func aWindowThatOnlyTouchesTheEdgeBetweenDisplaysHasNoSegmentOnTheOtherSide() {
        let segments = CaptureOutlineGeometry.segments(for: DesktopRect(x: 3340, y: 0, width: 100, height: 100), displays: [main, right])
        #expect(segments.map(\.displayIndex) == [0])
    }

    @Test func anEmptyWindowGivesNoSegment() {
        #expect(CaptureOutlineGeometry.segments(for: DesktopRect(x: 10, y: 10, width: 0, height: 100), displays: [main]).isEmpty)
    }
}
