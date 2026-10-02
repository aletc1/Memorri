import Foundation
import Testing
@testable import MemorriCore

@Suite struct ReferenceClockTests {
    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private let en = [Locale(identifier: "en_US"), Locale(identifier: "es_ES")]
    private let es = [Locale(identifier: "es_ES"), Locale(identifier: "en_US")]
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date { SyntheticTime.date(y, m, d, h, min, zone: "Europe/Madrid") }
    private var capture: Date { at(2026, 10, 14, 9, 12) }

    private func line(_ n: Int, _ text: String, x: Int = 100, y: Int, w: Int = 220, h: Int = 18) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: h), confidence: 0.9)
    }

    private func window(_ key: String = "w0", lines: [RecognisedLine] = [], frame: PixelBox = PixelBox(x: 100, y: 100, width: 1000, height: 800)) -> VisibleWindow {
        VisibleWindow(key: key, appName: "App", title: "Title", bundleID: nil, frame: frame, visible: [frame], visibleShare: 0.3, lines: lines)
    }

    private func screen(desktop: [RecognisedLine] = [], window w: VisibleWindow? = nil) -> VisibleScreen {
        VisibleScreen(windows: [w ?? window()], desktopLines: desktop)
    }

    private func find(_ screen: VisibleScreen, remote: Bool = false, window: VisibleWindow? = nil, capture time: Date? = nil, locales: [Locale]? = nil) -> ReferenceClock {
        ReferenceClock.find(window: window ?? screen.windows.first, remote: remote, screen: screen, captureTime: time ?? capture, timezone: madrid, pictureHeight: 1000,
                            locales: locales ?? en)
    }

    // MARK: the screen's clock

    @Test func theMenuBarClockIsTheReference() {
        let result = find(screen(desktop: [line(1, "Wed 14 Oct 09:12", x: 1800, y: 5)]))
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 14, 9, 12) && !result.isGuess)
    }

    @Test func aSpanishClockIsRead() {
        let result = find(screen(desktop: [line(1, "Jue 1 oct 20:31", x: 1800, y: 5)]), capture: at(2026, 10, 1, 20, 30), locales: es)
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 1, 20, 31))
    }

    @Test func aNumericDateWithATwelveHourTimeIsRead() {
        let result = find(screen(desktop: [line(1, "Thu 10/1/2026 11:01 AM", x: 1700, y: 5)]), capture: at(2026, 10, 1, 11, 0))
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 1, 11, 1))
    }

    @Test func theYearOfAClockThatWritesNoneIsTheOneWhereTheWeekdayFits() {
        // 14 October is a Wednesday in 2026 only (Tuesday in 2025, Thursday in 2027).
        let fits = find(screen(desktop: [line(1, "Wed 14 Oct 09:12", x: 1800, y: 5)]))
        #expect(fits.source == .screenClock && fits.instant == at(2026, 10, 14, 9, 12))
    }

    @Test func aTimeAloneTakesTheCapturesDateInItsOwnTime() {
        let result = find(screen(desktop: [line(1, "09:40", x: 1900, y: 5, w: 60)]))
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 14, 9, 40))
    }

    @Test func aTimeOnItsOwnLineTakesTheDateOnTheLineBesideIt() {
        let result = find(screen(desktop: [line(1, "20:31", x: 1900, y: 4, w: 60, h: 12), line(2, "01/10/2026", x: 1880, y: 16, w: 90, h: 12)]),
                          capture: at(2026, 10, 1, 20, 30), locales: es)
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 1, 20, 31))
    }

    @Test func aLineOutsideTheTopStripIsNotAClock() {
        let result = find(screen(desktop: [line(1, "Wed 14 Oct 09:12", x: 1800, y: 500)]))
        #expect(result.source == .capture && result.instant == capture)
    }

    // MARK: a remote window's own clock

    @Test func aRemoteWindowsOwnClockBeatsTheMenuBarAndMayBeHoursAway() {
        // A desktop inside the window shows its own time (6 hours behind), at the bottom of the window.
        let own = [line(1, "Wed 14 Oct 03:12", x: 900, y: 880, w: 180)]
        let result = find(screen(desktop: [line(2, "Wed 14 Oct 09:12", x: 1800, y: 5)], window: window(lines: own)), remote: true)
        #expect(result.source == .windowClock && result.instant == at(2026, 10, 14, 3, 12) && !result.isGuess)
    }

    @Test func theClockAtTheTopOfARemoteWindowCountsToo() {
        let own = [line(1, "Wed 14 Oct 03:12", x: 900, y: 104, w: 180)]
        #expect(find(screen(window: window(lines: own)), remote: true).source == .windowClock)
    }

    @Test func aWindowThatIsNotRemoteDoesNotGiveItsOwnClock() {
        let own = [line(1, "Wed 14 Oct 03:12", x: 900, y: 880, w: 180)]
        let result = find(screen(desktop: [line(2, "Wed 14 Oct 09:12", x: 1800, y: 5)], window: window(lines: own)), remote: false)
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 14, 9, 12))
    }

    @Test func aRemoteWindowWithNoClockOfItsOwnFallsBackToTheMenuBar() {
        let own = [line(1, "Inbox", x: 300, y: 500)]
        let result = find(screen(desktop: [line(2, "Wed 14 Oct 09:12", x: 1800, y: 5)], window: window(lines: own)), remote: true)
        #expect(result.source == .screenClock)
    }

    // MARK: what is not believed

    @Test func aClockMoreThanADayFromTheCaptureIsIgnoredAndFlagged() {
        let result = find(screen(desktop: [line(1, "Sat 1 Aug 10:00", x: 1800, y: 5)]))
        #expect(result.source == .captureFarClock && result.instant == capture && result.isGuess)
    }

    @Test func aClockJustUnderADayAwayIsBelieved() {
        let result = find(screen(desktop: [line(1, "Tue 13 Oct 09:40", x: 1800, y: 5)]))
        #expect(result.source == .screenClock && !result.isGuess)
    }

    @Test func noClockGivesTheCaptureTimeAndIsAGuessOnlyWhenWindowsAreKnown() {
        let withWindows = find(screen(window: window(lines: [line(1, "Inbox", y: 500)])))
        #expect(withWindows.source == .capture && withWindows.instant == capture && withWindows.isGuess)
        let whole = VisibleScreen(windows: [VisibleWindow(key: "all", appName: nil, title: nil, bundleID: nil, frame: PixelBox(x: 0, y: 0, width: 2000, height: 1000),
                                                          visible: [PixelBox(x: 0, y: 0, width: 2000, height: 1000)], visibleShare: 1, lines: [line(1, "Inbox", y: 500)])],
                                  desktopLines: [])
        let result = find(whole)
        #expect(result.source == .capture && result.instant == capture && !result.isGuess)
    }

    @Test func aCaptureWithNoStackLooksForTheClockAtTheTopOfThePicture() {
        let whole = VisibleScreen(windows: [VisibleWindow(key: "all", appName: nil, title: nil, bundleID: nil, frame: PixelBox(x: 0, y: 0, width: 2000, height: 1000),
                                                          visible: [PixelBox(x: 0, y: 0, width: 2000, height: 1000)], visibleShare: 1,
                                                          lines: [line(1, "Wed 14 Oct 09:12", x: 1800, y: 5), line(2, "Inbox", y: 500)])], desktopLines: [])
        let result = find(whole)
        #expect(result.source == .screenClock && result.instant == at(2026, 10, 14, 9, 12) && !result.isGuess)
    }

    // MARK: A window capture has no menu bar (spec 013)

    private func windowOnly(_ w: VisibleWindow, remote: Bool = false, capture time: Date? = nil) -> ReferenceClock {
        ReferenceClock.find(window: w, remote: remote, screen: VisibleScreen(windows: [w], desktopLines: []), captureTime: time ?? capture, timezone: madrid,
                            pictureHeight: 1000, locales: en, windowOnly: true)
    }

    @Test func aRemoteWindowsOwnClockIsTheReferenceInAWindowCapture() {
        let frame = PixelBox(x: 0, y: 0, width: 1200, height: 1000)
        let w = window(lines: [line(1, "Thu 15 Oct 20:31", x: 1000, y: 970)], frame: frame)
        let result = windowOnly(w, remote: true, capture: at(2026, 10, 15, 8, 0))
        #expect(result.source == .windowClock && result.instant == at(2026, 10, 15, 20, 31) && !result.isGuess)
    }

    @Test func noClockInAWindowCaptureUsesTheCaptureTimeWithoutAGuessFlag() {
        let w = window(lines: [line(1, "Meeting at 10", y: 300)], frame: PixelBox(x: 0, y: 0, width: 1200, height: 1000))
        for remote in [false, true] {
            let result = windowOnly(w, remote: remote)
            #expect(result.source == .capture && result.instant == capture && !result.isGuess)
        }
    }

    @Test func aFarClockInAWindowCaptureIsStillNotBelievedAndFlagged() {
        let frame = PixelBox(x: 0, y: 0, width: 1200, height: 1000)
        let w = window(lines: [line(1, "Mon 2 Nov 20:31", x: 1000, y: 970)], frame: frame)
        let result = windowOnly(w, remote: true)
        #expect(result.source == .captureFarClock && result.instant == capture && result.isGuess)
    }

    @Test func theTopOfAWindowIsNeverReadAsAScreenClockInAWindowCapture() {
        // A line in the top strip of the picture that looks like a clock, in a window that is not remote.
        let w = window(lines: [line(1, "Wed 14 Oct 11:11", x: 900, y: 5)], frame: PixelBox(x: 0, y: 0, width: 1200, height: 1000))
        let result = windowOnly(w, remote: false)
        #expect(result.source == .capture && result.instant == capture)
        // The same line on a capture of screens (windowOnly false) is read as the menu bar clock.
        let screens = ReferenceClock.find(window: w, remote: false, screen: VisibleScreen(windows: [w, window("w1")], desktopLines: []),
                                          captureTime: capture, timezone: madrid, pictureHeight: 1000, locales: en)
        #expect(screens.source == .capture && screens.isGuess)
    }

    @Test func withoutWindowOnlyNothingChanged() {
        let result = find(screen(desktop: [line(1, "Wed 14 Oct 09:12", x: 1800, y: 5)]))
        #expect(result.source == .screenClock && !result.isGuess)
        let none = find(VisibleScreen(windows: [window("w0"), window("w1")], desktopLines: []))
        #expect(none.source == .capture && none.isGuess)
    }
}
