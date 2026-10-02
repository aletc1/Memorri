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
}
