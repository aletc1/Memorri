import CoreGraphics
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
}
