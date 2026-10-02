import Foundation
import Testing
@testable import MemorriCore

@Suite struct VisibleScreenTests {
    private let width = 2000, height = 1000

    private func line(_ n: Int, _ text: String = "text", x: Int, y: Int) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: 100, height: 20), confidence: 0.9)
    }

    private func window(_ app: String, stack: Int?, _ x: Int, _ y: Int, _ w: Int, _ h: Int, bundle: String? = nil, title: String? = nil) -> WindowInfo {
        WindowInfo(appName: app, bundleID: bundle ?? "com.example.\(app.lowercased())", title: title ?? app, frame: PixelBox(x: x, y: y, width: w, height: h), stack: stack)
    }

    /// Four lines at the given corner of a window (enough to keep it).
    private func lines(from first: Int, x: Int, y: Int) -> [RecognisedLine] {
        (0..<4).map { line(first + $0, "L\(first + $0)", x: x + 20, y: y + 20 + $0 * 30) }
    }

    @Test func theVisibleRegionOfAWindowIsItsFrameMinusTheWindowsInFront() throws {
        let front = window("Mail", stack: 0, 1000, 100, 800, 600)
        let back = window("Calendar", stack: 1, 100, 100, 1000, 600)
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 1000, y: 100) + lines(from: 11, x: 100, y: 100),
                                         windows: [back, front], pictureWidth: width, pictureHeight: height)
        let mail = try #require(screen.windows.first { $0.appName == "Mail" })
        let calendar = try #require(screen.windows.first { $0.appName == "Calendar" })
        #expect(mail.visible == [PixelBox(x: 1000, y: 100, width: 800, height: 600)])
        #expect(mail.visibleShare == Double(800 * 600) / Double(width * height))
        // the calendar's frame reaches x = 1100; the mail covers 1000...1100 of it
        let visibleArea = calendar.visible.reduce(0) { $0 + $1.width * $1.height }
        #expect(visibleArea == 900 * 600)
        #expect(calendar.visible.allSatisfy { $0.x + $0.width <= 1000 })
        #expect(calendar.frame == PixelBox(x: 100, y: 100, width: 1000, height: 600))
    }

    @Test func windowsComeFrontToBackWithTheStackIndexAsKey() {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0) + lines(from: 11, x: 1000, y: 0) + lines(from: 21, x: 0, y: 500),
                                         windows: [window("C", stack: 7, 0, 500, 900, 400), window("A", stack: 2, 0, 0, 900, 400), window("B", stack: 4, 1000, 0, 900, 400)],
                                         pictureWidth: width, pictureHeight: height)
        #expect(screen.windows.map(\.key) == ["w2", "w4", "w7"])
        #expect(screen.windows.map(\.appName) == ["A", "B", "C"])
    }

    @Test func aLineBelongsToTheWindowWhoseVisibleRegionHoldsItsCentre() throws {
        let front = window("Mail", stack: 0, 600, 100, 800, 600)
        let back = window("Browser", stack: 1, 100, 100, 1500, 700)
        let behind = line(1, "covered by the mail", x: 700, y: 300)                   // inside both frames: the mail's
        let beside = line(2, "browser only", x: 150, y: 300)
        let inMail = lines(from: 10, x: 600, y: 100)
        let inBrowser = lines(from: 20, x: 100, y: 500)
        let screen = VisibleScreen.split(lines: [behind, beside] + inMail + inBrowser, windows: [front, back], pictureWidth: width, pictureHeight: height)
        let mail = try #require(screen.windows.first { $0.appName == "Mail" }), browser = try #require(screen.windows.first { $0.appName == "Browser" })
        #expect(mail.lines.map(\.n).contains(1))
        #expect(!browser.lines.map(\.n).contains(1))
        #expect(browser.lines.map(\.n).contains(2))
        #expect(Set(mail.lines.map(\.n)) == Set([1] + inMail.map(\.n)))
    }

    @Test func linesKeepTheirGlobalNumbersAndOrder() throws {
        let screen = VisibleScreen.split(lines: lines(from: 40, x: 100, y: 100), windows: [window("Calendar", stack: 0, 0, 0, 900, 600), window("Other", stack: 1, 1000, 0, 900, 600)],
                                         pictureWidth: width, pictureHeight: height)
        let calendar = try #require(screen.windows.first { $0.appName == "Calendar" })
        #expect(calendar.lines.map(\.n) == [40, 41, 42, 43])
    }

    @Test func linesOutsideEveryWindowAreTheDesktop() {
        let menuBar = line(1, "Thu 1 Oct 20:31", x: 1700, y: 5)
        let screen = VisibleScreen.split(lines: [menuBar] + lines(from: 10, x: 100, y: 100) + lines(from: 20, x: 1000, y: 100),
                                         windows: [window("A", stack: 0, 100, 100, 700, 500), window("B", stack: 1, 1000, 100, 700, 500)],
                                         pictureWidth: width, pictureHeight: height)
        #expect(screen.desktopLines.map(\.text) == ["Thu 1 Oct 20:31"])
        #expect(screen.windows.allSatisfy { !$0.lines.map(\.n).contains(1) })
    }

    @Test func aWindowWithUnderTwoPercentVisibleOrFewerThanThreeLinesIsDropped() {
        let big = window("Big", stack: 0, 0, 0, 1000, 800)
        let sliver = window("Sliver", stack: 1, 990, 0, 400, 50)                    // about 1% of the picture is visible
        let quiet = window("Quiet", stack: 2, 1100, 400, 800, 500)                 // plenty of area, two lines only
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0) + [line(10, x: 1200, y: 500), line(11, x: 1200, y: 540)] + [line(20, x: 1200, y: 10)],
                                         windows: [big, sliver, quiet], pictureWidth: width, pictureHeight: height)
        #expect(screen.windows.map(\.appName) == ["Big"])
    }

    @Test func theAppItselfAndTheSystemUIAreDropped() {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 100, y: 100) + lines(from: 11, x: 1000, y: 100) + lines(from: 21, x: 100, y: 600) + lines(from: 31, x: 1000, y: 600),
                                         windows: [window("Calendar", stack: 0, 100, 100, 700, 400),
                                                   window("Memorri", stack: 1, 1000, 100, 700, 400, bundle: "com.aletc1.memorri"),
                                                   window("Dock", stack: 2, 100, 600, 700, 300, bundle: "com.apple.dock"),
                                                   window("Control Centre", stack: 3, 1000, 600, 700, 300, bundle: "com.apple.controlcenter")],
                                         pictureWidth: width, pictureHeight: height)
        #expect(screen.windows.map(\.appName) == ["Calendar"])
    }

    @Test func aMenuDrawnOverACalendarStillHidesItAndAddsNothingToIt() throws {
        let menu = window("Control Centre", stack: 0, 300, 150, 400, 300, bundle: "com.apple.controlcenter")
        let calendar = window("Calendar", stack: 1, 100, 100, 1000, 700)
        let under = lines(from: 1, x: 350, y: 200)                                   // calendar text the menu covers
        let menuText = lines(from: 10, x: 320, y: 160)                               // the menu's own text, inside both frames
        let visibleText = lines(from: 20, x: 700, y: 400)
        let screen = VisibleScreen.split(lines: under + menuText + visibleText, windows: [menu, calendar], pictureWidth: width, pictureHeight: height)
        let kept = try #require(screen.windows.first { $0.appName == "Calendar" })
        #expect(screen.windows.count == 1)
        #expect(Set(kept.lines.map(\.n)) == Set(visibleText.map(\.n)))                // neither the covered lines nor the menu's
        #expect(!screen.desktopLines.contains { $0.n < 20 })                          // and none of them turns into desktop text
        // the covered part is not in the calendar's visible region
        #expect(!kept.visible.contains { box in box.x <= 350 && 350 < box.x + box.width && box.y <= 200 && 200 < box.y + box.height })
    }

    @Test func aCaptureWithNoStackOrOneWindowIsOneWindowCoveringThePicture() throws {
        let text = lines(from: 1, x: 100, y: 100) + [line(9, "menu bar", x: 10, y: 4)]
        let none = VisibleScreen.split(lines: text, windows: [], pictureWidth: width, pictureHeight: height)
        let noStack = VisibleScreen.split(lines: text, windows: [window("A", stack: nil, 0, 0, 900, 500), window("B", stack: nil, 900, 0, 900, 500)], pictureWidth: width, pictureHeight: height)
        let one = VisibleScreen.split(lines: text, windows: [window("A", stack: 0, 0, 0, 900, 500)], pictureWidth: width, pictureHeight: height)
        for screen in [none, noStack, one] {
            let all = try #require(screen.windows.first)
            #expect(screen.windows.count == 1 && all.key == "all")
            #expect(all.frame == PixelBox(x: 0, y: 0, width: width, height: height))
            #expect(all.visible == [all.frame] && all.visibleShare == 1)
            #expect(all.lines == text && screen.desktopLines.isEmpty)
            #expect(!screen.perWindow)
        }
    }

    @Test func whenEveryWindowIsDroppedTheCaptureIsOneWindowAsBefore() throws {
        let text = [line(1, "a", x: 100, y: 100), line(2, "b", x: 1200, y: 100)]
        let screen = VisibleScreen.split(lines: text, windows: [window("A", stack: 0, 0, 0, 900, 500), window("B", stack: 1, 1000, 0, 900, 500)], pictureWidth: width, pictureHeight: height)
        #expect(screen.windows.map(\.key) == ["all"] && screen.windows[0].lines == text && !screen.perWindow)
    }

    @Test func framesAreClippedToThePicture() throws {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 1500, y: 700) + lines(from: 11, x: 100, y: 100),
                                         windows: [window("Edge", stack: 0, 1500, 700, 1000, 800), window("Home", stack: 1, 0, 0, 900, 500)], pictureWidth: width, pictureHeight: height)
        let edge = try #require(screen.windows.first { $0.appName == "Edge" })
        #expect(edge.frame == PixelBox(x: 1500, y: 700, width: 500, height: 300))
        #expect(screen.perWindow)
    }

    // MARK: A window the user chose (spec 013)

    @Test func aChosenWindowIsTheOnlyWindowWithEveryLine() throws {
        let only = window("Mail", stack: 0, 0, 0, width, height)
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0), windows: [only], pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(screen.perWindow)
        let mail = try #require(screen.windows.first)
        #expect(screen.windows.count == 1 && mail.key == "w0" && mail.appName == "Mail" && mail.title == "Mail")
        #expect(mail.lines.count == 4 && mail.visibleShare == 1 && screen.desktopLines.isEmpty)
        #expect(mail.visible == [PixelBox(x: 0, y: 0, width: width, height: height)])
    }

    @Test func aChosenWindowIsKeptEvenWithFewLinesLittleShareOrASystemBundle() throws {
        let sparse = VisibleScreen.split(lines: [line(1, x: 10, y: 10)], windows: [window("Terminal", stack: 0, 0, 0, width, height)],
                                         pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(sparse.perWindow && sparse.windows.first?.key == "w0" && sparse.windows.first?.lines.count == 1)
        let empty = VisibleScreen.split(lines: [], windows: [window("Terminal", stack: 0, 0, 0, width, height)],
                                        pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(empty.perWindow && empty.windows.count == 1 && empty.windows[0].lines.isEmpty)
        let small = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0), windows: [window("Notes", stack: 0, 0, 0, 100, 50)],
                                        pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(small.windows.first?.visibleShare ?? 1 < VisibleScreen.minimumVisibleShare)
        let system = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0),
                                         windows: [window("Dock", stack: 0, 0, 0, width, height, bundle: "com.apple.dock")],
                                         pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(system.perWindow && system.windows.first?.bundleID == "com.apple.dock")
    }

    @Test func aChosenWindowWithoutAStackNumberStillGetsKeyW0() {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0), windows: [window("Mail", stack: nil, 0, 0, width, height)],
                                         pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(screen.windows.map(\.key) == ["w0"])
    }

    @Test func aChosenWindowFrameIsClippedToThePictureAndLinesOutsideItAreDesktopLines() throws {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0) + [line(9, "outside", x: 1500, y: 800)],
                                         windows: [window("Mail", stack: 0, -100, -50, 1100, 650)], pictureWidth: width, pictureHeight: height, chosenWindow: true)
        let mail = try #require(screen.windows.first)
        #expect(mail.frame == PixelBox(x: 0, y: 0, width: 1000, height: 600))
        #expect(mail.lines.count == 4 && screen.desktopLines.map(\.n) == [9])
    }

    @Test func aChosenCaptureWithNoRecordedWindowIsReadAsOneWholePicture() {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0), windows: [], pictureWidth: width, pictureHeight: height, chosenWindow: true)
        #expect(!screen.perWindow && screen.windows.map(\.key) == [VisibleScreen.wholePicture])
    }

    @Test func withoutChosenWindowOneWindowStillReadsAsTheWholePicture() {
        let screen = VisibleScreen.split(lines: lines(from: 1, x: 0, y: 0), windows: [window("Mail", stack: 0, 0, 0, 800, 600)],
                                         pictureWidth: width, pictureHeight: height)
        #expect(!screen.perWindow && screen.windows.map(\.key) == [VisibleScreen.wholePicture])
    }
}
