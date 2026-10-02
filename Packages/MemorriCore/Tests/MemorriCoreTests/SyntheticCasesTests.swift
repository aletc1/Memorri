import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MemorriCore

@Suite struct SyntheticCasesTests {
    private let cases = SyntheticCases.all

    private func files(in folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result[String(url.resolvingSymlinksInPath().path.dropFirst(root.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private func pixels(_ data: Data) -> (width: Int, height: Int, distinctSamples: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) {
                let p = base + (y * image.width + x) * 4
                seen.insert(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
            }
        }
        return (image.width, image.height, seen.count)
    }

    @Test func thereAreEnoughCasesWithUniqueNames() {
        #expect(cases.count >= 33)
        #expect(Set(cases.map(\.name)).count == cases.count)
    }

    @Test func everyScreenKindAppearsAtLeastTwice() {
        for kind in ScreenKind.allCases {
            #expect(cases.filter { $0.expected.screenKind == kind.rawValue }.count >= 2, "\(kind)")
        }
    }

    @Test func theRequiredSituationsAreCovered() {
        let required = ["relative-date", "header-date", "x-needs-y", "block-30", "block-60", "block-90", "block-120", "text-only-no-end",
                        "midnight-other-zone", "clock-12h", "clock-24h", "lang-en", "lang-es", "remote-frame", "look-outlook",
                        "look-apple-mail", "look-teams", "look-web", "empty-picture", "text-free-picture", "deadline"]
        let present = Set(cases.flatMap(\.features))
        for feature in required { #expect(present.contains(feature), "\(feature)") }
    }

    @Test func featuresAgreeWithTheExpectedAnswers() {
        for c in cases {
            let tags = Dictionary((c.expected.tags ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
            #expect(c.features.contains("clock-12h") == (tags["clock_style"] == "12h"), "\(c.name)")
            #expect(c.features.contains("lang-es") == (tags["language"] == "es"), "\(c.name)")
            for f in c.expected.findings where c.features.contains("block-90") && f.title == "Design review" {
                #expect(f.end!.timeIntervalSince(f.start!) == 90 * 60, "\(c.name)")
            }
        }
    }

    @Test func generatingTwiceGivesIdenticalBytes() throws {
        let temp = TempDirectory()
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        try SyntheticCases.generate(into: a)
        try SyntheticCases.generate(into: b)
        let first = try files(in: a), second = try files(in: b)
        #expect(first.count == cases.count * 3)
        #expect(first == second)
    }

    @Test func generatedCasesLoadBackAndDescribeTheirPictures() throws {
        let temp = TempDirectory()
        let out = temp.url.appendingPathComponent("synthetic")
        try SyntheticCases.generate(into: out)
        let loaded = try GoldenCase.loadAll(in: out)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.cases.count == cases.count)
        for c in loaded.cases {
            #expect(c.origin == .synthetic, "\(c.name)")
            let picture = try #require(pixels(try Data(contentsOf: c.pictureURL)), "\(c.name)")
            #expect([picture.width, picture.height] == c.meta.displaySize, "\(c.name)")
            #expect(picture.distinctSamples > 1, "\(c.name) is blank")
            let drawn = c.expected.lines ?? []
            let textFree = c.name.contains("text-free")
            #expect(drawn.isEmpty == (textFree || c.name.contains("empty")), "\(c.name)")
            for line in drawn {
                let box = try #require(line.box, "\(c.name): \(line.text)")
                #expect(box.count == 4 && box[0] >= 0 && box[1] >= 0 && box[0] + box[2] <= picture.width && box[1] + box[3] <= picture.height,
                        "\(c.name): \(line.text) is outside the picture")
            }
        }
    }

    @Test func nothingIsWrittenOutsideTheOutputFolder() throws {
        let temp = TempDirectory()
        let parent = temp.url.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try SyntheticCases.generate(into: parent.appendingPathComponent("out"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["out"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["parent"])
    }

    @Test func findingsAreSelfConsistent() {
        for c in cases {
            for f in c.expected.findings {
                if let start = f.start, let end = f.end { #expect(end > start, "\(c.name): \(f.title)") }
                #expect(["appointment", "task", "reminder", "deadline"].contains(f.kind), "\(c.name): \(f.kind)")
            }
            #expect(c.meta.context == nil || c.expected.context == c.meta.context?.name, "\(c.name)")
        }
    }

    // MARK: windows (spec 011)

    private var windowCases: [GoldenCaseSummary] { cases.filter { $0.features.contains("multi-window") } }

    @Test func theMultiWindowCasesAreThereWithTheirWindowsStackedAndNamed() {
        let names = Set(windowCases.map(\.name))
        #expect(names.isSuperset(of: ["windows-calendar-and-mail", "windows-calendar-under-browser", "windows-two-calendars-same-event",
                                      "windows-month-other-month-menu-clock", "windows-remote-clock-other-zone"]))
        for c in windowCases {
            let stacks = c.meta.windows.compactMap(\.stack)
            #expect(c.meta.windows.count >= 2 && stacks.count == c.meta.windows.count && Set(stacks).count == stacks.count, "\(c.name)")
            #expect(c.meta.windows.allSatisfy { $0.frame.count == 4 && $0.frame[0] >= 0 && $0.frame[1] >= 0 && $0.frame[0] + $0.frame[2] <= c.meta.displaySize[0]
                                                && $0.frame[1] + $0.frame[3] <= c.meta.displaySize[1] }, "\(c.name)")
            #expect(!c.expected.findings.isEmpty, "\(c.name)")
            for f in c.expected.findings { #expect(f.window.map { key in stacks.contains { "w\($0)" == key } } == true, "\(c.name): \(f.title) names no window") }
        }
    }

    @Test func everyMultiWindowCaseHasAMenuBarClockAmongItsLines() {
        for c in windowCases {
            #expect((c.expected.lines ?? []).contains { $0.text.hasPrefix("Wed 14 Oct ") && ($0.box?[1] ?? 99) < 28 }, "\(c.name)")
        }
    }

    @Test func noExpectedLineIsUnderAWindowInFrontOfTheOneThatDrewIt() {
        // A reader sees only what is not covered: the text of the calendar behind the browser is not among the expected lines.
        let under = windowCases.first { $0.name == "windows-calendar-under-browser" }!
        let browser = under.meta.windows.first { $0.app == "Safari" }!
        for line in under.expected.lines ?? [] where line.text.hasPrefix("Thu") || line.text.hasPrefix("Fri") {
            let box = line.box!
            #expect(!(box[0] >= browser.frame[0] && box[1] >= browser.frame[1]), "\(line.text) is covered by the browser and should not be expected")
        }
        #expect(!(under.expected.lines ?? []).contains { $0.text == "Thu 12" || $0.text == "Fri 13" })
    }

    @Test func theCalendarUnderTheBrowserIsOnAnotherMonthThanTheCapturesAndTheBrowserNamesTheCapturesMonth() {
        let under = windowCases.first { $0.name == "windows-calendar-under-browser" }!
        #expect(under.features.contains("other-month"))
        #expect(under.expected.findings.allSatisfy { f in f.start.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/Madrid")!, from: $0).month == 3 } == true })
        #expect((under.expected.lines ?? []).contains { $0.text.contains("October 2026") })
        #expect(under.meta.capturedAt > Date(timeIntervalSince1970: 1_790_000_000))      // October 2026
    }

    @Test func theSameEventInTwoWindowsIsExpectedOncePerWindow() {
        let two = windowCases.first { $0.name == "windows-two-calendars-same-event" }!
        let review = two.expected.findings.filter { $0.title == "Design review" }
        #expect(review.count == 2 && Set(review.compactMap(\.window)).count == 2 && Set(review.compactMap(\.start)).count == 1)
    }

    @Test func theTrackedFolderHoldsTheWindowCasesAsTheGeneratorDrawsThem() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/golden/synthetic")
        let temp = TempDirectory()
        try SyntheticCases.generate(into: temp.url)
        for name in windowCases.map(\.name) {
            for file in ["meta.json", "expected.json", "screenshot.png"] {
                let tracked = try Data(contentsOf: folder.appendingPathComponent(name).appendingPathComponent(file))
                let drawn = try Data(contentsOf: temp.url.appendingPathComponent(name).appendingPathComponent(file))
                #expect(tracked == drawn, "run memorri-eval generate-synthetic: \(name)/\(file) changed")
            }
        }
    }

    @Test func aWindowCaseRoundTripsItsStackAndWindowKeysThroughTheFiles() throws {
        let temp = TempDirectory()
        try SyntheticCases.generate(into: temp.url)
        let loaded = try GoldenCase.loadAll(in: temp.url).cases.first { $0.name == "windows-calendar-and-mail" }!
        #expect(loaded.meta.windows.map(\.stack) == [0, 1])
        #expect(Set(loaded.expected.findings.compactMap(\.window)) == ["w0", "w1"])
    }

    @Test func oldCasesDoNotMentionStacksOrWindowsInTheirFiles() throws {
        let temp = TempDirectory()
        try SyntheticCases.generate(into: temp.url)
        for name in ["calendar-week-outlook-24h-blocks", "email-apple-mail-invite"] {
            let meta = try String(contentsOf: temp.url.appendingPathComponent(name).appendingPathComponent("meta.json"), encoding: .utf8)
            let expected = try String(contentsOf: temp.url.appendingPathComponent(name).appendingPathComponent("expected.json"), encoding: .utf8)
            #expect(!meta.contains("\"stack\"") && !expected.contains("\"window\""), "\(name)")
        }
    }

    @Test func theMonthCaseIsOnFebruaryUnderAMenuBarClockOfOctober() {
        let c = windowCases.first { $0.name == "windows-month-other-month-menu-clock" }!
        #expect(c.features.contains("other-month") && c.expected.screenKind == "email")
        let lines = (c.expected.lines ?? []).map(\.text)
        #expect(lines.contains("February 2026") && lines.contains("Wed 14 Oct 09:12"))
        let calendarFindings = c.expected.findings.filter { $0.window == "w1" }
        #expect(calendarFindings.count == 3 && calendarFindings.allSatisfy { f in f.start.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/Madrid")!, from: $0).month == 2 } == true })
        #expect(c.expected.findings.contains { $0.window == "w0" && $0.title == "Contract review" })
    }

    @Test func theRemoteCaseHasItsOwnClockADayAheadOfTheMacsAndExpectsTomorrowFromIt() {
        let c = windowCases.first { $0.name == "windows-remote-clock-other-zone" }!
        let lines = (c.expected.lines ?? []).map(\.text)
        #expect(lines.contains("Wed 14 Oct 20:30") && lines.contains("Thu 15 Oct 03:30"))
        #expect(c.features.contains("remote-clock"))
        let meeting = c.expected.findings.first { $0.title == "Planning meeting" }
        #expect(meeting?.start == SyntheticTime.date(2026, 10, 16, 10, 0, zone: "America/New_York"))      // tomorrow from Thursday 15, not from Wednesday 14
        #expect(c.meta.context?.name == "Customer A" && c.expected.context == "Customer A")
        #expect(c.meta.capturedAt == SyntheticTime.date(2026, 10, 14, 20, 30, zone: "Europe/Madrid"))
    }

    // MARK: window captures (spec 013)

    private var captureCases: [GoldenCaseSummary] { cases.filter { $0.features.contains("window-capture") } }

    @Test func theWindowCaptureCasesAreOneWindowThatFillsThePictureWithNoMenuBar() {
        #expect(Set(captureCases.map(\.name)) == ["window-capture-mail", "window-capture-month-other-month", "window-capture-remote-clock",
                                                  "window-capture-covered", "window-capture-terminal"])
        for c in captureCases {
            #expect(c.meta.scope == .window, "\(c.name)")
            #expect(c.meta.windows.count == 1 && c.meta.windows[0].stack == 0 && c.meta.windows[0].frame == [0, 0, c.meta.displaySize[0], c.meta.displaySize[1]], "\(c.name)")
            for f in c.expected.findings { #expect(f.window == "w0", "\(c.name): \(f.title)") }
            // No menu bar: nothing that reads as a clock at the top edge of the picture beyond the window's own title bar.
            #expect(!(c.expected.lines ?? []).contains { $0.text == "Wed 14 Oct 09:12" }, "\(c.name)")
        }
        #expect(cases.filter { !$0.features.contains("window-capture") }.allSatisfy { $0.meta.scope == nil })
    }

    @Test func theWindowCaptureCasesExpectWhatTheirWindowSaysAndNothingElse() {
        func named(_ name: String) -> GoldenCaseSummary { captureCases.first { $0.name == name }! }
        #expect(named("window-capture-mail").expected.findings.map(\.title) == ["Planning meeting"] && named("window-capture-mail").expected.screenKind == "email")
        let month = named("window-capture-month-other-month")
        #expect(month.expected.screenKind == "calendar_month" && month.expected.findings.count == 3)
        #expect(month.expected.findings.allSatisfy { f in f.start.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/Madrid")!, from: $0).month == 2 } == true })
        let remote = named("window-capture-remote-clock")
        #expect(remote.features.contains("remote-clock") && (remote.expected.lines ?? []).map(\.text).contains("Thu 15 Oct 03:30"))
        #expect(remote.expected.findings.first?.start == SyntheticTime.date(2026, 10, 16, 10, 0, zone: "America/New_York"))
        let covered = named("window-capture-covered")
        #expect(covered.expected.findings.map(\.title).sorted() == ["Coffee with Sam", "Daily standup", "Design review"])
        #expect((covered.expected.lines ?? []).map(\.text).contains("Charged 84%"))
        let terminal = named("window-capture-terminal")
        #expect(terminal.expected.findings.isEmpty && terminal.expected.screenKind == "other")
        #expect(terminal.expected.tags?.first { $0.key == "theme" }?.value == "dark")      // drawn on a dark background
    }
}
