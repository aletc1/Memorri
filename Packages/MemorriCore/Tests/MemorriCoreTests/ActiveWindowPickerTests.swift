import Testing
@testable import MemorriCore

@Suite struct ActiveWindowPickerTests {
    private let own: Int32 = 100
    private func window(_ id: UInt32, pid: Int32, layer: Int = 0, onScreen: Bool = true,
                        width: Double = 800, height: Double = 600, title: String? = nil) -> WindowCandidate {
        WindowCandidate(windowID: id, processID: pid, layer: layer, isOnScreen: onScreen,
                        frame: DesktopRect(x: 0, y: 0, width: width, height: height), appName: "App \(pid)", bundleID: "com.example.\(pid)", title: title)
    }

    @Test func theFrontMostOrdinaryWindowOfTheFrontmostApplicationWins() {
        let list = [window(1, pid: 7), window(2, pid: 7), window(3, pid: 8)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .window(list[0]))
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 8, ownProcessID: own) == .window(list[2]))
    }

    @Test func windowsOfOtherApplicationsInFrontAreIgnored() {
        let list = [window(1, pid: 9), window(2, pid: 7)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .window(list[1]))
    }

    @Test func aFloatingPanelAboveLayerZeroIsSkipped() {
        let list = [window(1, pid: 7, layer: 3), window(2, pid: 7)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .window(list[1]))
    }

    @Test func windowsThatAreNotOnTheScreenAreSkipped() {
        let list = [window(1, pid: 7, onScreen: false), window(2, pid: 7)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .window(list[1]))
    }

    @Test func memorrisOwnWindowInFrontIsRefused() {
        let list = [window(1, pid: own), window(2, pid: 7)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: own, ownProcessID: own) == .ownWindow)
    }

    @Test func memorrisOwnWindowsAreNeverChosenForAnotherApplication() {
        let list = [window(1, pid: own), window(2, pid: 7)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .window(list[1]))
    }

    @Test func anApplicationWithoutAQualifyingWindowGivesNone() {
        let list = [window(1, pid: 7, layer: 25), window(2, pid: 8)]
        #expect(ActiveWindowPicker.pick(candidates: list, frontmostProcessID: 7, ownProcessID: own) == .none)
        #expect(ActiveWindowPicker.pick(candidates: [], frontmostProcessID: 7, ownProcessID: own) == .none)
    }

    @Test func noFrontmostApplicationGivesNone() {
        #expect(ActiveWindowPicker.pick(candidates: [window(1, pid: 7)], frontmostProcessID: nil, ownProcessID: own) == .none)
    }

    @Test func aTinyWindowStillQualifiesButAnEmptyOneDoesNot() {
        let tiny = window(1, pid: 7, width: 12, height: 9), empty = window(2, pid: 7, width: 0, height: 0)
        #expect(ActiveWindowPicker.pick(candidates: [empty, tiny], frontmostProcessID: 7, ownProcessID: own) == .window(tiny))
        #expect(ActiveWindowPicker.pick(candidates: [empty], frontmostProcessID: 7, ownProcessID: own) == .none)
    }

    @Test func aTransparentWindowIsSkipped() {
        let hidden = WindowCandidate(windowID: 1, processID: 7, frame: DesktopRect(x: 0, y: -32, width: 3440, height: 32), alpha: 0)
        let real = window(2, pid: 7)
        #expect(ActiveWindowPicker.pick(candidates: [hidden, real], frontmostProcessID: 7, ownProcessID: own) == .window(real))
        #expect(ActiveWindowPicker.pick(candidates: [hidden], frontmostProcessID: 7, ownProcessID: own) == .none)
    }

    @Test func aWindowOffEveryScreenIsSkippedWhenTheScreensAreKnown() {
        let screen = DesktopRect(x: 0, y: 0, width: 3440, height: 1440)
        let above = WindowCandidate(windowID: 1, processID: 7, frame: DesktopRect(x: 0, y: -32, width: 3440, height: 32))
        let real = window(2, pid: 7)
        #expect(ActiveWindowPicker.pick(candidates: [above, real], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .window(real))
        #expect(ActiveWindowPicker.pick(candidates: [above], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .none)
        // Without the screens the window cannot be told to be off them.
        #expect(ActiveWindowPicker.pick(candidates: [above, real], frontmostProcessID: 7, ownProcessID: own) == .window(above))
    }

    @Test func aWindowPartlyOnAScreenQualifies() {
        let screen = DesktopRect(x: 0, y: 0, width: 1000, height: 800)
        let partly = WindowCandidate(windowID: 1, processID: 7, frame: DesktopRect(x: 900, y: 700, width: 400, height: 300))
        #expect(ActiveWindowPicker.pick(candidates: [partly], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .window(partly))
    }

    @Test func anUntitledStripAcrossADisplayIsTheChromeOfAFullScreenAppNotAWindow() {
        let screen = DesktopRect(x: 0, y: 0, width: 3440, height: 1440)
        let toolbar = WindowCandidate(windowID: 1, processID: 7, frame: DesktopRect(x: 0, y: 30, width: 3440, height: 32))
        let real = WindowCandidate(windowID: 2, processID: 7, frame: screen, title: "notes.txt")
        #expect(ActiveWindowPicker.pick(candidates: [toolbar, real], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .window(real))
        #expect(ActiveWindowPicker.pick(candidates: [toolbar], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .none)
    }

    @Test func aSmallOrTitledWindowIsNotAStrip() {
        let screen = DesktopRect(x: 0, y: 0, width: 3440, height: 1440)
        let small = WindowCandidate(windowID: 1, processID: 7, frame: DesktopRect(x: 100, y: 100, width: 300, height: 30))
        let titledBar = WindowCandidate(windowID: 2, processID: 7, frame: DesktopRect(x: 0, y: 30, width: 3440, height: 32), title: "Timer")
        let thick = WindowCandidate(windowID: 3, processID: 7, frame: DesktopRect(x: 0, y: 30, width: 3440, height: 200))
        for candidate in [small, titledBar, thick] {
            #expect(ActiveWindowPicker.pick(candidates: [candidate], frontmostProcessID: 7, ownProcessID: own, screens: [screen]) == .window(candidate))
        }
    }
}
