import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import MemorriCore

/// The per-window path of `AnalysisPipeline` (spec 011): the windows call, one extraction per relevant window that is not a month grid, and the old
/// path for a capture with no stack, one window, or a windows call that fails.
@Suite struct WindowPipelineTests {
    private let settings = ModelStepSettings(model: "m", think: .off, timeout: 60, modelThinks: false)
    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private var captureTime: Date { SyntheticTime.date(2026, 10, 14, 9, 12, zone: "Europe/Madrid") }

    private func line(_ n: Int, _ text: String, x: Int, y: Int, w: Int = 200) -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: 18), confidence: 0.9)
    }

    private func window(_ app: String, stack: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, title: String? = nil) -> WindowInfo {
        WindowInfo(appName: app, bundleID: "com.example.\(app.lowercased())", title: title ?? app, frame: PixelBox(x: x, y: y, width: w, height: h), stack: stack)
    }

    /// A month grid of October 2026 (28 Sep to 2 Nov), its title, and two entries, laid out from `origin`; numbers start at `first`.
    private func monthLines(first: Int, originX: Int = 0, originY: Int = 100, step: (Int, Int) = (200, 130)) -> [RecognisedLine] {
        var lines = [line(first, "October 2026", x: originX + 20, y: originY - 60, w: 200)]
        for (i, number) in (Array(28...30) + Array(1...31) + [1, 2]).enumerated() {
            lines.append(line(first + 1 + i, "\(number)", x: originX + (i % 7) * step.0 + 10, y: originY + (i / 7) * step.1, w: 22))
        }
        let next = first + 1 + 36
        lines.append(line(next, "09:00 Budget meeting", x: originX + 10, y: originY + step.1 + 30, w: 160))      // Monday 5 October
        return lines
    }

    private let mailLines = ["From: Ana Ruiz", "Subject: Planning", "Planning meeting tomorrow at 10:00", "Date: Wed 14 Oct 2026 09:00"]
    private let terminalLines = ["$ ls -la", "drwxr-xr-x  5 user  staff", "-rw-r--r--  1 user  staff  grep results", "$ make build"]

    private func texts(_ items: [String], from first: Int, x: Int, y: Int) -> [RecognisedLine] {
        items.enumerated().map { line(first + $0.offset, $0.element, x: x, y: y + $0.offset * 30, w: 300) }
    }

    private func entry(_ key: String, relevant: Bool, kind: ScreenKind, remote: Bool = false) -> String {
        #"{"key":"\#(key)","relevant":\#(relevant),"kind":"\#(kind.rawValue)","confidence":0.9,"remote":\#(remote),"calendar_name":""}"#
    }

    private func windowsAnswer(_ entries: [String]) -> String {
        #"{"windows":[\#(entries.joined(separator: ","))],"application":"Outlook","platform_look":"macos","theme":"light","remote_session":{"is_remote":false,"client":""}}"#
    }

    private struct Rig {
        let recogniser: FakeTextRecogniser
        let model: FakeModelChatting
        let pipeline: AnalysisPipeline
    }

    private func makeRig(lines: [RecognisedLine]) -> Rig {
        let recogniser = FakeTextRecogniser(lines: lines)
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        model.answer(whenSchemaHas: "screen_kind", ClassificationTests.goodAnswer.replacingOccurrences(of: "calendar_week", with: "email"))
        return Rig(recogniser: recogniser, model: model, pipeline: AnalysisPipeline(recogniser: recogniser, model: model, time: FakeTimeSource(1000)))
    }

    private func input(windows: [WindowInfo], width: Int = 2400, height: Int = 1000, reuse: PipelineInput.Reuse = .init()) -> PipelineInput {
        PipelineInput(image: makeTestImage(width: width, height: height), classificationJPEG: Data("c".utf8), classificationSize: (1024, 427),
                      analysisJPEG: Data("a".utf8), analysisSize: (2048, 853), macTimezone: madrid, captureTime: captureTime,
                      locales: [Locale(identifier: "en_US"), Locale(identifier: "es_ES")], reuse: reuse, windows: windows)
    }

    /// Calendar (month) at the left, a mail in front of its right edge, a terminal behind everything, and the menu bar line.
    private struct Desktop {
        var lines: [RecognisedLine]
        var windows: [WindowInfo]
        var mailFirst: Int
        var terminalFirst: Int
    }

    private func desktop() -> Desktop {
        let calendar = monthLines(first: 1)                                    // lines 1...38, inside x 0...1450, y 40...800
        let mail = texts(mailLines, from: 39, x: 1550, y: 120)
        let terminal = texts(terminalLines, from: 43, x: 100, y: 850)
        let menuBar = [line(47, "Wed 14 Oct 09:12", x: 2200, y: 10)]
        return Desktop(lines: calendar + mail + terminal + menuBar,
                       windows: [window("Mail", stack: 0, 1500, 60, 880, 640), window("Calendar", stack: 1, 0, 40, 1450, 760),
                                 window("Terminal", stack: 2, 0, 40, 2400, 960)],
                       mailFirst: 39, terminalFirst: 43)
    }

    private func answers(_ rig: Rig, _ d: Desktop, mailFindings: String = #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[41],"start_text":"10:00","date_text":"tomorrow"}]}"#) {
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email), entry("w1", relevant: true, kind: .calendarMonth),
                                                                  entry("w2", relevant: false, kind: .other)]))
        rig.model.answer(whenSchemaHas: "findings", mailFindings)
    }

    // MARK: the flow

    @Test func aCalendarAMailAndATerminalMakeTheWindowsCallOneExtractionForTheMailAndNoneForTheTerminal() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        answers(rig, d)
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(rig.model.requests(whereSchemaHas: "windows").count == 1)
        #expect(rig.model.requests(whereSchemaHas: "findings").count == 1)           // the mail; the month grid is read by geometry, the terminal not at all
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").isEmpty)           // the windows call replaces classify
        #expect(result.steps.map(\.step) == ["windows", "extract:w0"])
        #expect(result.steps[0].promptVersion == "windows-v1" && result.steps[1].promptVersion == "extract-email-v13")
        #expect(Set(result.findings.compactMap(\.windowKey)) == ["w0", "w1"])
        #expect(result.findings.first { $0.windowKey == "w0" }?.title == "Planning meeting")
        #expect(result.findings.first { $0.windowKey == "w1" }?.title == "Budget meeting")
        #expect(result.readBy == nil)                                                 // a model read at least one window
    }

    @Test func everyFindingCarriesItsWindowKeyAndEachWindowIsDatedByItsOwnText() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        answers(rig, d)
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(result.findings.allSatisfy { $0.windowKey != nil })
        let budget = try #require(result.findings.first { $0.title == "Budget meeting" })
        #expect(budget.start == SyntheticTime.date(2026, 10, 5, 9, 0, zone: "Europe/Madrid"))
        #expect(budget.provenance["start"] == FieldProvenance(origin: .read, rule: "month-cell"))
        let meeting = try #require(result.findings.first { $0.title == "Planning meeting" })
        #expect(meeting.start == SyntheticTime.date(2026, 10, 15, 10, 0, zone: "Europe/Madrid"))       // "tomorrow" from the capture's Wednesday
    }

    @Test func theExtractionOfAWindowGetsOnlyThatWindowsLines() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        answers(rig, d)
        _ = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        let prompt = try #require(rig.model.requests(whereSchemaHas: "findings").first).prompt
        #expect(prompt.contains("L41 ") && prompt.contains("Planning meeting tomorrow at 10:00"))
        for other in ["Budget meeting", "grep results", "make build", "October 2026"] { #expect(!prompt.contains(other), "leaks \(other)") }
        #expect(prompt.contains("These lines are one window of the screen; cite only these line numbers."))
    }

    @Test func theLinesOfAWindowCoveredByOneInFrontAreNotGivenToItsExtraction() async throws {
        let mail = texts(mailLines, from: 1, x: 1050, y: 120)
        let underMail = [line(5, "text under the mail", x: 1100, y: 300, w: 300)]               // inside both frames: it belongs to the mail
        let notes = texts(["Notes: buy milk", "Notes: call Ana", "Notes: renew passport", "Notes: book flights"], from: 6, x: 220, y: 120)
        let rig = makeRig(lines: mail + underMail + notes)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email), entry("w1", relevant: true, kind: .document)]))
        _ = try await rig.pipeline.analyse(input(windows: [window("Mail", stack: 0, 1000, 60, 1000, 600), window("Notes", stack: 1, 200, 60, 1500, 800)]), settings: settings)
        let prompts = rig.model.requests(whereSchemaHas: "findings").map(\.prompt)
        #expect(prompts.count == 2)
        let notesPrompt = try #require(prompts.first { $0.contains("Notes: buy milk") }), mailPrompt = try #require(prompts.first { $0.contains("From: Ana Ruiz") })
        #expect(!notesPrompt.contains("text under the mail") && !notesPrompt.contains("From: Ana Ruiz"))
        #expect(mailPrompt.contains("text under the mail") && !mailPrompt.contains("Notes: buy milk"))
    }

    @Test func aCitationToALineOutsideItsWindowIsDiscardedAsOutsideTheWindow() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        // The mail's extraction cites a calendar line (3) and a terminal line (44) as well as its own (41).
        answers(rig, d, mailFindings: #"{"findings":[{"kind":"appointment","title":"Good","cited_lines":[41],"start_text":"10:00"},{"kind":"appointment","title":"Calendar leak","cited_lines":[3],"start_text":"10:00"},{"kind":"appointment","title":"Mixed","cited_lines":[41,44],"start_text":"10:00"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(result.findings.filter { $0.windowKey == "w0" }.map(\.title) == ["Good"])
        #expect(result.discards.map(\.reason).filter { $0 == "outside the window" }.count == 2)
        #expect(Set(result.discards.filter { $0.reason == "outside the window" }.map(\.title)) == ["Calendar leak", "Mixed"])
    }

    @Test func aMonthGridMakesNoExtractionCall() async throws {
        let calendar = monthLines(first: 1), notes = texts(terminalLines, from: 50, x: 1550, y: 120)
        let rig = makeRig(lines: calendar + notes)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .calendarMonth), entry("w1", relevant: false, kind: .other)]))
        let result = try await rig.pipeline.analyse(input(windows: [window("Calendar", stack: 0, 0, 40, 1450, 760), window("Terminal", stack: 1, 1500, 40, 880, 760)]), settings: settings)
        #expect(rig.model.requests(whereSchemaHas: "findings").isEmpty && result.steps.map(\.step) == ["windows"])
        #expect(result.findings.map(\.title) == ["Budget meeting"] && result.readBy == MonthEntries.version)
    }

    @Test func theWindowsAreRecordedWithTheirJudgement() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        answers(rig, d)
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(result.windows.map(\.windowKey) == ["w0", "w1", "w2"])
        #expect(result.windows.map(\.relevant) == [true, true, false])
        #expect(result.windows.map(\.kind) == [.email, .calendarMonth, nil])
        #expect(result.windows.map(\.appName) == ["Mail", "Calendar", "Terminal"])
        #expect(result.windows.allSatisfy { $0.promptVersion == "windows-v1" && $0.visibleShare > 0 })
        #expect(result.windowsRead == 2)
        #expect(result.classification.kind == .email && result.classification.application == "Outlook")
    }

    @Test func theCallsNeverExceedOnePlusTheRelevantWindowsThatAreNotMonthGrids() async throws {
        // Six windows in two rows of three, 1000 x 900 each.
        var lines: [RecognisedLine] = [], windows: [WindowInfo] = []
        let kinds: [(ScreenKind, Bool)] = [(.email, true), (.chat, true), (.document, true), (.calendarWeek, true), (.calendarMonth, true), (.other, false)]
        var next = 1
        for (i, _) in kinds.enumerated() {
            let x = (i % 3) * 1000, y = (i / 3) * 900
            windows.append(window("App\(i)", stack: i, x, y, 1000, 900))
            if i == 4 { let grid = monthLines(first: next, originX: x, originY: y + 100, step: (135, 100)); lines += grid; next += grid.count }
            else { let text = texts(["one \(i)", "two \(i)", "three \(i)", "four \(i)"], from: next, x: x + 20, y: y + 100); lines += text; next += text.count }
        }
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer(kinds.enumerated().map { entry("w\($0.offset)", relevant: $0.element.1, kind: $0.element.0) }))
        let result = try await rig.pipeline.analyse(input(windows: windows, width: 3000, height: 1800), settings: settings)
        let relevantNotMonth = kinds.filter { $0.1 && $0.0 != .calendarMonth }.count
        #expect(rig.model.callCount <= 1 + relevantNotMonth && rig.model.callCount == 1 + relevantNotMonth)
        #expect(result.steps.map(\.step) == ["windows", "extract:w0", "extract:w1", "extract:w2", "extract:w3"])
        #expect(result.windows.count == 6)
    }

    // MARK: fallbacks

    @Test func anInvalidWindowsAnswerTakesTheOldPathAndRecordsTheFailure() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        rig.model.answer(whenSchemaHas: "windows", "this is not json")
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Old path","cited_lines":[41],"start_text":"10:00"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(result.steps.map(\.step) == ["windows", "classify", "extract"])
        #expect(result.steps[0].failure == "invalid answer" && result.steps[1].failure == nil)
        #expect(result.windows.isEmpty && result.findings.map(\.title) == ["Old path"] && result.findings.allSatisfy { $0.windowKey == nil })
    }

    @Test func anAnswerThatDoesNotNameTheWindowsGivenTakesTheOldPathAndRecordsTheFailure() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        // Right shape and right keys, but one window twice and one left out.
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email), entry("w0", relevant: true, kind: .calendarMonth), entry("w2", relevant: false, kind: .other)]))
        let result = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(result.steps.map(\.step) == ["windows", "classify", "extract"])
        #expect(result.steps[0].failure == "answer does not name the windows" && result.windows.isEmpty)
        // A key that was not given does not even pass the schema.
        let other = makeRig(lines: d.lines)
        other.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email), entry("w1", relevant: true, kind: .calendarMonth), entry("w9", relevant: false, kind: .other)]))
        let again = try await other.pipeline.analyse(input(windows: d.windows), settings: settings)
        #expect(again.steps.map(\.step) == ["windows", "classify", "extract"] && again.steps[0].failure == "invalid answer")
    }

    @Test func aTimeoutOfTheWindowsCallTakesTheOldPathButAnUnreachableServerStops() async throws {
        let d = desktop()
        let slow = makeRig(lines: d.lines)
        slow.model.failWith(OllamaClientError.timedOut)
        do { _ = try await slow.pipeline.analyse(input(windows: d.windows), settings: settings); Issue.record("the old path fails too, with the same error") }
        catch let failure as AnalysisFailure { #expect(failure.steps.map(\.step) == ["windows", "classify"] && failure.error == .transient("timed out")) }
        let down = makeRig(lines: d.lines)
        down.model.failWith(OllamaClientError.unreachable)
        do { _ = try await down.pipeline.analyse(input(windows: d.windows), settings: settings); Issue.record("should fail") }
        catch let failure as AnalysisFailure { #expect(failure.error == .serverUnavailable && failure.steps.map(\.step) == ["windows"]) }
    }

    @Test func aCaptureWithNoStackOrOneWindowTakesTheOldPathAndGivesTheOldFindings() async throws {
        let d = desktop()
        let answer = #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[41],"start_text":"10:00","date_text":"tomorrow"}]}"#
        func run(windows: [WindowInfo]) async throws -> (AnalysisResult, Rig) {
            let rig = makeRig(lines: d.lines)
            rig.model.answer(whenSchemaHas: "findings", answer)
            return (try await rig.pipeline.analyse(input(windows: windows), settings: settings), rig)
        }
        let (none, noneRig) = try await run(windows: [])
        let (one, oneRig) = try await run(windows: [window("Mail", stack: 0, 0, 0, 2400, 1000)])
        let (unstacked, _) = try await run(windows: [WindowInfo(appName: "A", bundleID: nil, title: nil, frame: PixelBox(x: 0, y: 0, width: 100, height: 100)),
                                                    WindowInfo(appName: "B", bundleID: nil, title: nil, frame: PixelBox(x: 100, y: 0, width: 100, height: 100))])
        for rig in [noneRig, oneRig] { #expect(rig.model.requests(whereSchemaHas: "windows").isEmpty && rig.model.callCount == 2) }
        for result in [none, one, unstacked] {
            #expect(result.steps.map(\.step) == ["classify", "extract"] && result.windows.isEmpty && result.findings.allSatisfy { $0.windowKey == nil })
        }
        func essence(_ r: AnalysisResult) -> [String] {
            r.findings.map { "\($0.title)|\($0.start.map(String.init(describing:)) ?? "-")|\($0.citedLines)|\($0.provenance.mapValues(\.rule).sorted { $0.key < $1.key })" }
        }
        #expect(essence(none) == essence(one) && essence(one) == essence(unstacked))
    }

    @Test func aReusedWindowsAnswerSkipsTheCall() async throws {
        let d = desktop(), rig = makeRig(lines: d.lines)
        answers(rig, d)
        let first = try await rig.pipeline.analyse(input(windows: d.windows), settings: settings)
        let stored = try #require(first.steps.first { $0.step == "windows" }?.rawAnswer.flatMap { WindowsAnswer.parse(storedAnswer: $0, expecting: ["w0", "w1", "w2"]) })
        let again = makeRig(lines: d.lines)
        again.model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        let result = try await again.pipeline.analyse(input(windows: d.windows, reuse: .init(lines: d.lines, windows: stored)), settings: settings)
        #expect(again.model.requests(whereSchemaHas: "windows").isEmpty && result.steps.map(\.step) == ["extract:w0"])
        #expect(result.windows.map(\.windowKey) == ["w0", "w1", "w2"])
    }

    // MARK: dates come from the window being read (spec 011, US2)

    /// A week view in a window at (x, y): an optional title, headers `days` (text, column), and the block "13:00 Design review" in the third column.
    /// Returns its lines (numbered from `first`) and the number of the block's line.
    private func weekWindow(first: Int, x: Int, y: Int, title: String?, days: [String]) -> (lines: [RecognisedLine], block: Int) {
        var lines: [RecognisedLine] = [], n = first
        if let title { lines.append(line(n, title, x: x + 20, y: y + 20, w: 300)); n += 1 }
        for (i, day) in days.enumerated() { lines.append(line(n, day, x: x + 100 + i * 220, y: y + 80, w: 80)); n += 1 }
        lines.append(line(n, "13:00 Design review", x: x + 100 + 2 * 220 + 10, y: y + 300, w: 200))
        return (lines, n)
    }

    private func start(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 13) -> Date { SyntheticTime.date(y, m, d, h, 0, zone: "Europe/Madrid") }

    @Test func aBrowserWindowThatNamesAnotherMonthDoesNotNameTheCalendarsMonth() async throws {
        let calendar = weekWindow(first: 1, x: 0, y: 60, title: "March 9 – 13, 2026", days: ["Mon 9", "Tue 10", "Wed 11", "Thu 12", "Fri 13"])
        let browser = texts(["Quarterly revenue report - October 2026", "Oct 14, 2026   Actual   1,287,950", "Oct 21, 2026   Forecast   1,402,300", "Nov 4, 2026   Forecast   1,512,750"],
                            from: calendar.block + 1, x: 1400, y: 120)
        let rig = makeRig(lines: calendar.lines + browser)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: false, kind: .other), entry("w1", relevant: true, kind: .calendarWeek)]))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[\#(calendar.block)],"start_text":"13:00"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: [window("Safari", stack: 0, 1350, 60, 800, 600), window("Calendar", stack: 1, 0, 60, 1300, 700)]), settings: settings)
        let finding = try #require(result.findings.first)
        #expect(finding.start == start(2026, 3, 11))                      // Wednesday of the week the calendar's own title names
        #expect(finding.provenance["start"]?.origin == .read && finding.windowKey == "w1")
    }

    @Test func aPartOfTheCalendarCoveredByAnotherWindowIsNotRead() async throws {
        // The calendar's right columns (Thu, Fri) are under a browser: their headers are not in its visible text, and the browser's are not its own.
        let calendar = weekWindow(first: 1, x: 0, y: 60, title: "March 9 – 13, 2026", days: ["Mon 9", "Tue 10", "Wed 11"])
        let hidden = [line(calendar.block + 1, "Thu 12", x: 1050, y: 140, w: 80), line(calendar.block + 2, "Fri 13", x: 1270, y: 140, w: 80)]       // under the browser
        let rig = makeRig(lines: calendar.lines + hidden + texts(["a", "b", "c"], from: calendar.block + 3, x: 1400, y: 300))
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: false, kind: .other), entry("w1", relevant: true, kind: .calendarWeek)]))
        let result = try await rig.pipeline.analyse(input(windows: [window("Safari", stack: 0, 1000, 60, 1100, 700), window("Calendar", stack: 1, 0, 60, 1500, 700)]), settings: settings)
        let prompt = try #require(rig.model.requests(whereSchemaHas: "findings").first).prompt
        #expect(!prompt.contains("Thu 12") && !prompt.contains("Fri 13") && prompt.contains("Wed 11"))
        #expect(result.windows.first { $0.windowKey == "w1" }?.visibleShare ?? 1 < 0.5)
    }

    @Test func aCalendarWithTooLittleVisibleToNameAMonthGivesGuessedDates() async throws {
        // No title and only weekday-and-number headers: nothing in the window says which month, so the capture's month is a guess.
        let calendar = weekWindow(first: 1, x: 0, y: 60, title: nil, days: ["Mon 12", "Tue 13", "Wed 14", "Thu 15", "Fri 16"])
        let rig = makeRig(lines: calendar.lines + texts(["x", "y", "z"], from: calendar.block + 1, x: 1400, y: 300))
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: false, kind: .other), entry("w1", relevant: true, kind: .calendarWeek)]))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[\#(calendar.block)],"start_text":"13:00"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: [window("Browser", stack: 0, 1350, 60, 800, 600), window("Calendar", stack: 1, 0, 60, 1300, 700)]), settings: settings)
        let finding = try #require(result.findings.first)
        #expect(finding.provenance["start"]?.origin == .inferred && finding.provenance["start"]?.reason == "month-assumed")
    }

    @Test func twoCalendarWindowsOnDifferentMonthsAreEachReadInTheirOwn() async throws {
        let left = weekWindow(first: 1, x: 0, y: 60, title: "March 9 – 13, 2026", days: ["Mon 9", "Tue 10", "Wed 11", "Thu 12", "Fri 13"])
        let right = weekWindow(first: left.block + 1, x: 1250, y: 60, title: "October 12 – 16, 2026", days: ["Mon 12", "Tue 13", "Wed 14", "Thu 15", "Fri 16"])
        let rig = makeRig(lines: left.lines + right.lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .calendarWeek), entry("w1", relevant: true, kind: .calendarWeek)]))
        // Both extractions get this answer; each keeps the finding that cites its own window's line, the other is outside its window.
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Design review","cited_lines":[\#(left.block)],"start_text":"13:00"},{"kind":"appointment","title":"Design review","cited_lines":[\#(right.block)],"start_text":"13:00"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: [window("Calendar", stack: 0, 1200, 60, 1150, 700), window("Calendar", stack: 1, 0, 60, 1200, 700)]), settings: settings)
        let byWindow = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.windowKey ?? "", $0.start) })
        #expect(result.findings.count == 2)
        #expect(byWindow["w1"] == start(2026, 3, 11) && byWindow["w0"] == start(2026, 10, 14))
        #expect(result.discards.filter { $0.reason == "outside the window" }.count == 2)
    }

    @Test func theStoredReadingOfAWindowKeepsTheKindItWasReadAsNotTheModelsMistake() async throws {
        let left = weekWindow(first: 1, x: 0, y: 60, title: "March 9 – 13, 2026", days: ["Mon 9", "Tue 10", "Wed 11", "Thu 12", "Fri 13"])
        let right = weekWindow(first: left.block + 1, x: 1250, y: 60, title: "October 12 – 16, 2026", days: ["Mon 12", "Tue 13", "Wed 14", "Thu 15", "Fri 16"])
        let rig = makeRig(lines: left.lines + right.lines)
        // The model calls the week in front a day view; five day headers across it make it a week.
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .calendarDay), entry("w1", relevant: true, kind: .calendarWeek)]))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[]}"#)
        let result = try await rig.pipeline.analyse(input(windows: [window("Calendar", stack: 0, 1200, 60, 1150, 700), window("Calendar", stack: 1, 0, 60, 1200, 700)]), settings: settings)
        #expect(result.windows.map(\.kind) == [.calendarWeek, .calendarWeek])
    }

    // MARK: the reference clock (spec 011, US3)

    /// A remote desktop window (stack 0) with its own taskbar clock (06:00 behind the Mac) and a mail in it that says "tomorrow".
    private func remoteDesktop(clock: String?) -> (lines: [RecognisedLine], windows: [WindowInfo]) {
        var lines = texts(mailLines, from: 1, x: 300, y: 150)
        lines.append(line(5, "Wed 14 Oct 09:12", x: 2200, y: 10))                                              // the Mac's menu bar
        if let clock { lines.append(line(6, clock, x: 1900, y: 940, w: 200)) }                                  // the remote taskbar
        lines += texts(["one", "two", "three"], from: lines.count + 1, x: 300, y: 600)
        return (lines, [window("Citrix Viewer", stack: 0, 100, 60, 2000, 940)])
    }

    private func remoteRig(_ d: (lines: [RecognisedLine], windows: [WindowInfo])) -> Rig {
        let rig = makeRig(lines: d.lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email, remote: true)]))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[3],"start_text":"10:00","date_text":"tomorrow"}]}"#)
        return rig
    }

    @Test func aRemoteWindowsOwnClockIsTheReferenceForItsRelativeDates() async throws {
        let d = remoteDesktop(clock: "Thu 15 Oct 03:30")                       // already the 15th there: tomorrow is the 16th
        let rig = remoteRig(d)
        let result = try await rig.pipeline.analyse(input(windows: d.windows + [window("Other", stack: 1, 0, 0, 10, 10)]), settings: settings)
        let finding = try #require(result.findings.first)
        #expect(finding.start == start(2026, 10, 16, 10))
        #expect(finding.provenance["start"]?.origin == .read)
        #expect(result.reference?.source == .windowClock && result.reference?.instant == SyntheticTime.date(2026, 10, 15, 3, 30, zone: "Europe/Madrid"))
    }

    @Test func aWindowThatIsNotRemoteUsesTheMenuBarClock() async throws {
        let d = remoteDesktop(clock: "Thu 15 Oct 03:30")
        let rig = makeRig(lines: d.lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .email, remote: false)]))
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[3],"start_text":"10:00","date_text":"tomorrow"}]}"#)
        let result = try await rig.pipeline.analyse(input(windows: d.windows + [window("Other", stack: 1, 0, 0, 10, 10)]), settings: settings)
        #expect(result.findings.first?.start == start(2026, 10, 15, 10))
        #expect(result.reference?.source == .screenClock)
    }

    @Test func aFarClockResolvesFromTheCaptureTimeAndFlagsTheDatesThatDependOnIt() async throws {
        let d = remoteDesktop(clock: "Sat 1 Aug 10:00")
        let rig = remoteRig(d)
        let result = try await rig.pipeline.analyse(input(windows: d.windows + [window("Other", stack: 1, 0, 0, 10, 10)]), settings: settings)
        let finding = try #require(result.findings.first)
        #expect(finding.start == start(2026, 10, 15, 10))
        #expect(finding.provenance["start"] == FieldProvenance(origin: .inferred, rule: "relative-day", reason: "reference-assumed"))
        #expect(result.reference?.source == .captureFarClock)
    }

    @Test func withWindowsAndNoClockAtAllRelativeDatesAreGuessesWithoutThemTheyAreNot() async throws {
        var d = remoteDesktop(clock: nil)
        d.lines = d.lines.filter { $0.text != "Wed 14 Oct 09:12" }
        let rig = remoteRig(d)
        let guessed = try await rig.pipeline.analyse(input(windows: d.windows + [window("Other", stack: 1, 0, 0, 10, 10)]), settings: settings)
        #expect(guessed.findings.first?.provenance["start"]?.reason == "reference-assumed" && guessed.reference?.source == .capture)
        // The same capture with no stack is read as one window, as before: the capture's time, no flag.
        let again = remoteRig(d)
        let plain = try await again.pipeline.analyse(input(windows: []), settings: settings)
        #expect(plain.findings.first?.provenance["start"]?.reason == nil)
    }

    // MARK: a window the user chose (spec 013)

    private func chosenInput(_ lines: [RecognisedLine], app: String = "Mail", title: String? = nil, width: Int = 1200, height: Int = 800,
                             reuse: PipelineInput.Reuse = .init(), chosen: Bool = true) -> PipelineInput {
        PipelineInput(image: makeTestImage(width: width, height: height), classificationJPEG: Data("c".utf8), classificationSize: (1024, 683),
                      analysisJPEG: Data("a".utf8), analysisSize: (1200, 800), macTimezone: madrid, captureTime: captureTime,
                      locales: [Locale(identifier: "en_US"), Locale(identifier: "es_ES")], reuse: reuse,
                      windows: [window(app, stack: 0, 0, 0, width, height, title: title)], chosenWindow: chosen)
    }

    private let planning = #"{"findings":[{"kind":"appointment","title":"Planning meeting","cited_lines":[3],"start_text":"10:00","date_text":"tomorrow"}]}"#

    private func chosenRig(_ lines: [RecognisedLine], windows: String) -> Rig {
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "windows", windows)
        rig.model.answer(whenSchemaHas: "findings", planning)
        return rig
    }

    @Test func aChosenWindowIsAlwaysReadEvenWhenTheModelCallsItIrrelevant() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: false, kind: .other)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines, title: "Inbox"), settings: settings)
        #expect(rig.model.requests(whereSchemaHas: "windows").count == 1 && rig.model.requests(whereSchemaHas: "findings").count == 1)
        #expect(rig.model.requests(whereSchemaHas: "screen_kind").isEmpty)
        #expect(result.steps.map(\.step) == ["windows", "extract:w0"])
        #expect(result.findings.map(\.title) == ["Planning meeting"] && result.findings.first?.windowKey == "w0")
        let record = try #require(result.windows.first)
        #expect(result.windows.count == 1 && record.windowKey == "w0" && record.relevant && record.appName == "Mail" && record.title == "Inbox")
        #expect(result.windowsRead == 1)
    }

    @Test func aChosenWindowKeepsTheKindTheModelGave() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: true, kind: .email)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines), settings: settings)
        #expect(result.windows.first?.kind == .email && result.steps[1].promptVersion == "extract-email-v13")
    }

    @Test func aStoredWindowsAnswerThatCalledTheWindowIrrelevantIsOverriddenToo() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let stored = try #require(WindowsAnswer.parse(storedAnswer: windowsAnswer([entry("w0", relevant: false, kind: .other)]), expecting: ["w0"]))
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "findings", planning)
        let result = try await rig.pipeline.analyse(chosenInput(lines, reuse: .init(lines: lines, windows: stored)), settings: settings)
        #expect(rig.model.requests(whereSchemaHas: "windows").isEmpty && rig.model.requests(whereSchemaHas: "findings").count == 1)
        #expect(result.steps.map(\.step) == ["extract:w0"] && result.findings.count == 1 && result.windows.first?.relevant == true)
    }

    @Test func aChosenMonthGridIsReadByGeometryWithNoExtractionCall() async throws {
        let lines = monthLines(first: 1, originX: 0, originY: 100)
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: true, kind: .calendarMonth)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines, app: "Calendar", width: 1500, height: 900), settings: settings)
        #expect(rig.model.requests(whereSchemaHas: "findings").isEmpty && result.steps.map(\.step) == ["windows"])
        #expect(result.findings.map(\.title) == ["Budget meeting"] && result.readBy == MonthEntries.version)
        #expect(result.windows.first?.kind == .calendarMonth)
    }

    @Test func aChosenWindowWithNothingToFindGivesNoItemsAndNoError() async throws {
        let lines = texts(terminalLines, from: 1, x: 100, y: 100)
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "windows", windowsAnswer([entry("w0", relevant: false, kind: .other)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines, app: "Terminal"), settings: settings)
        #expect(result.findings.isEmpty && result.windows.first?.relevant == true && result.windows.first?.appName == "Terminal")
    }

    @Test func aChosenWindowWithTwoLinesIsStillKeptAndNamed() async throws {
        let lines = texts(["Hello", "World"], from: 1, x: 100, y: 100)
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: false, kind: .other)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines, app: "Notes"), settings: settings)
        #expect(result.windows.map(\.windowKey) == ["w0"] && result.windows.first?.appName == "Notes" && rig.model.requests(whereSchemaHas: "windows").count == 1)
    }

    @Test func aFailedWindowsCallReadsTheChosenPictureWholeAsBefore() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "windows", "this is not json")
        rig.model.answer(whenSchemaHas: "findings", #"{"findings":[{"kind":"appointment","title":"Old path","cited_lines":[3],"start_text":"10:00"}]}"#)
        let result = try await rig.pipeline.analyse(chosenInput(lines), settings: settings)
        #expect(result.steps.map(\.step) == ["windows", "classify", "extract"] && result.steps[0].failure == "invalid answer")
        #expect(result.findings.map(\.title) == ["Old path"] && result.windows.isEmpty)
    }

    @Test func aChosenWindowWithNoClockUsesTheCaptureTimeWithoutAGuessFlag() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: true, kind: .email)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines), settings: settings)
        #expect(result.reference?.source == .capture && result.reference?.isGuess == false)
        let finding = try #require(result.findings.first)
        #expect(finding.start == start(2026, 10, 15, 10) && finding.provenance["start"]?.reason == nil)
    }

    @Test func aChosenRemoteWindowReadsItsOwnTaskbarClock() async throws {
        var lines = texts(mailLines, from: 1, x: 100, y: 100)
        lines.append(line(5, "Thu 15 Oct 03:30", x: 900, y: 780, w: 200))          // the taskbar, in the bottom strip of the window picture
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: true, kind: .email, remote: true)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines, app: "Citrix Viewer"), settings: settings)
        #expect(result.reference?.source == .windowClock && result.findings.first?.start == start(2026, 10, 16, 10))
    }

    @Test func theTopOfAChosenPictureIsNeverReadAsAMenuBarClock() async throws {
        var lines = texts(mailLines, from: 1, x: 100, y: 100)
        lines.append(line(5, "Wed 14 Oct 11:11", x: 900, y: 5, w: 200))
        let rig = chosenRig(lines, windows: windowsAnswer([entry("w0", relevant: true, kind: .email)]))
        let result = try await rig.pipeline.analyse(chosenInput(lines), settings: settings)
        #expect(result.reference?.source == .capture)
    }

    @Test func aSingleWindowThatIsNotChosenStillTakesTheOldPath() async throws {
        let lines = texts(mailLines, from: 1, x: 100, y: 100)
        let rig = makeRig(lines: lines)
        rig.model.answer(whenSchemaHas: "findings", planning)
        let result = try await rig.pipeline.analyse(chosenInput(lines, chosen: false), settings: settings)
        #expect(result.steps.map(\.step) == ["classify", "extract"] && result.windows.isEmpty && rig.model.requests(whereSchemaHas: "windows").isEmpty)
    }

    // MARK: one block listed twice

    @Test func aBlockListedTwiceIsOneFindingWithWhatEachEntryGave() {
        let timed = FindingDraft(kind: .appointment, title: "Design review", citedLines: [28, 30], startText: "13:00")
        let place = FindingDraft(kind: .appointment, title: "design  review", citedLines: [30, 31], place: "Board room")
        let other = FindingDraft(kind: .appointment, title: "Team sync", citedLines: [40], startText: "10:00")
        let sameTitleElsewhere = FindingDraft(kind: .appointment, title: "Design review", citedLines: [99], startText: "09:00")
        let merged = AnalysisPipeline.mergingRepeats([timed, place, other, sameTitleElsewhere])
        #expect(merged.map(\.title) == ["Design review", "Team sync", "Design review"])
        #expect(merged[0].startText == "13:00" && merged[0].place == "Board room" && merged[0].citedLines == [28, 30, 31])
        #expect(merged[2].citedLines == [99])                        // a block of the same name that cites other lines is another block
    }

    @Test func aBlocksLengthIsMeasuredOnTheWindowsOwnPageNotTheDesktopsColour() {
        // The block is a 90-minute one in a white window on a dark desktop: measured against the desktop, its pastel fill would run into the white page.
        let canvas = SyntheticCanvas(width: 1200, height: 900, background: RGB(0x3B5B7F))
        canvas.fill(CGRect(x: 100, y: 100, width: 900, height: 700), RGB(0xFFFFFF))
        for h in 0..<9 { canvas.fill(CGRect(x: 160, y: 200 + Double(h) * 64, width: 800, height: 1), RGB(0xD0D0D0)) }
        canvas.fill(CGRect(x: 360, y: 200 + 5 * 64 + 2, width: 260, height: 94), RGB(0xFBE3C6))
        let title = canvas.text("13:00 Design review", x: 372, y: 200 + 5 * 64 + 8, size: 16, color: RGB(0x1C1C1C))
        var hours: [RecognisedLine] = []
        for h in 0..<9 {
            let box = canvas.text(String(format: "%02d:00", 8 + h), x: 112, y: 200 + Double(h) * 64 - 8, size: 14, color: RGB(0x707070), record: false)
            hours.append(RecognisedLine(n: h + 1, text: String(format: "%02d:00", 8 + h), box: PixelBox(x: Int(box.minX), y: Int(box.minY), width: Int(box.width), height: Int(box.height)), confidence: 0.9))
        }
        guard let data = try? canvas.pngData(), let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("no picture"); return
        }
        let box = PixelBox(x: Int(title.minX), y: Int(title.minY), width: Int(title.width), height: Int(title.height))
        let whole = BlockGeometry.duration(titleBox: box, lines: hours, image: image, columnWidth: 280)
        let geometry = AnalysisPipeline.Geometry.cut(of: image, frame: PixelBox(x: 100, y: 100, width: 900, height: 700), columnWidth: 280)
        let cut = BlockGeometry.duration(titleBox: PixelBox(x: box.x - geometry.origin.x, y: box.y - geometry.origin.y, width: box.width, height: box.height),
                                         lines: hours, image: geometry.image, columnWidth: 280)
        #expect(whole != 90)                                          // the desktop's colour as the page makes the fill look like part of the page
        #expect(cut == 90)
    }
}
