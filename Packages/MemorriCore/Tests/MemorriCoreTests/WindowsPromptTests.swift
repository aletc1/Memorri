import Foundation
import Testing
@testable import MemorriCore

@Suite struct WindowsPromptTests {
    private func window(_ key: String, app: String? = "Calendar", title: String? = "Calendar", frame: PixelBox = PixelBox(x: 1725, y: 40, width: 1705, height: 1285),
                        share: Double = 1, lines: [String] = ["Febrero de 2026", "lun", "mar"]) -> VisibleWindow {
        VisibleWindow(key: key, appName: app, title: title, bundleID: nil, frame: frame, visible: [frame], visibleShare: share,
                      lines: lines.enumerated().map { RecognisedLine(n: $0.offset + 1, text: $0.element, box: PixelBox(x: 0, y: $0.offset * 20, width: 50, height: 18), confidence: 0.9) })
    }

    @Test func theVersionIsWindowsV1() {
        #expect(ExtractionPrompts.windowsVersion == "windows-v1")
        #expect(ExtractionSchemas.windowsSchemaVersion == "schema-windows-v1")
    }

    @Test func thePromptListsKeyApplicationTitleFrameVisibleShareAndFirstLines() {
        let prompt = ExtractionPrompts.windowsPrompt(windows: [window("w1"), window("w3", app: "Mail", title: "Inbox", frame: PixelBox(x: 0, y: 0, width: 800, height: 600), share: 0.4, lines: ["From: Ana"])])
        #expect(prompt.contains("[w1] app: Calendar · title: Calendar · frame: 1725,40 1705x1285 · visible: 100%"))
        #expect(prompt.contains("[w3] app: Mail · title: Inbox · frame: 0,0 800x600 · visible: 40%"))
        #expect(prompt.contains(#"first lines: "Febrero de 2026" | "lun" | "mar""#))
        #expect(prompt.contains(#"first lines: "From: Ana""#))
    }

    @Test func thePromptShowsAtMostTwelveLinesOfAWindowAndNamesWhatIsUnknown() {
        let many = (1...20).map { "line number \($0)" }
        let prompt = ExtractionPrompts.windowsPrompt(windows: [window("w0", app: nil, title: nil, lines: many)])
        #expect(prompt.contains("line number 12") && !prompt.contains("line number 13"))
        #expect(prompt.contains("[w0] app: unknown · title: none"))
    }

    @Test func aLongLineIsCutInThePrompt() {
        let prompt = ExtractionPrompts.windowsPrompt(windows: [window("w0", lines: [String(repeating: "x", count: 400)])])
        #expect(!prompt.contains(String(repeating: "x", count: 200)))
    }

    @Test func thePromptAsksForEveryKeyAndForTheCaptureWideFields() {
        let prompt = ExtractionPrompts.windowsPrompt(windows: [window("w1")])
        for word in ["relevant", "kind", "remote", "application", "platform", "theme", "calendar"] { #expect(prompt.contains(word), "mentions \(word)") }
        for kind in ScreenKind.allCases { #expect(prompt.contains(kind.rawValue)) }
    }

    // MARK: schema

    static let answer = """
    {"windows":[{"key":"w0","relevant":true,"kind":"email","confidence":0.9,"remote":false,"calendar_name":""},
                {"key":"w1","relevant":false,"kind":"other","confidence":0.8,"remote":true,"calendar_name":""}],
     "application":"Outlook","platform_look":"windows","theme":"light","remote_session":{"is_remote":true,"client":"Citrix"}}
    """

    private func validate(_ text: String, keys: [String] = ["w0", "w1"]) -> Result<JSONValue, SchemaValidationError> {
        SchemaValidator.validate(text, against: ExtractionSchemas.windowsSchema(keys: keys))
    }

    @Test func theSchemaAcceptsAFullAnswer() {
        if case .failure(let error) = validate(Self.answer) { Issue.record("rejected: \(error)") }
    }

    @Test func theSchemaRejectsAnAnswerThatLeavesOutAKeyOrNamesAnUnknownOne() {
        let oneEntry = #"{"windows":[{"key":"w0","relevant":true,"kind":"email","confidence":0.9,"remote":false,"calendar_name":""}],"application":"","platform_look":"","theme":"","remote_session":{"is_remote":false,"client":""}}"#
        let unknown = Self.answer.replacingOccurrences(of: "\"w1\"", with: "\"w9\"")
        for bad in [oneEntry, unknown] {
            if case .success = validate(bad) { Issue.record("accepted: \(bad)") }
        }
    }

    @Test func theSchemaKeepsTheCaptureWideFieldsOfTheClassifyAnswer() {
        for missing in ["\"application\":\"Outlook\",", "\"platform_look\":\"windows\",", "\"theme\":\"light\",", "\"is_remote\":true,"] {
            if case .success = validate(Self.answer.replacingOccurrences(of: missing, with: "")) { Issue.record("accepted without \(missing)") }
        }
        if case .success = validate(Self.answer.replacingOccurrences(of: "\"email\"", with: "\"spreadsheet\"")) { Issue.record("accepted an unknown kind") }
    }

    @Test func theAnswerIsParsedAgainstTheKeysGiven() throws {
        let value = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(Self.answer.utf8)))
        let parsed = try #require(WindowsAnswer.parse(value, expecting: ["w0", "w1"]))
        #expect(parsed.judgements == [WindowJudgement(key: "w0", relevant: true, kind: .email, confidence: 0.9, remote: false),
                                      WindowJudgement(key: "w1", relevant: false, kind: nil, confidence: 0.8, remote: true)])
        #expect(parsed.application == "Outlook" && parsed.platformLook == "windows" && parsed.theme == "light" && parsed.isRemote && parsed.remoteClient == "Citrix")
        #expect(WindowsAnswer.parse(value, expecting: ["w0"]) == nil)                  // names a window that was not given
        #expect(WindowsAnswer.parse(value, expecting: ["w0", "w1", "w2"]) == nil)      // leaves one out
        let twice = Self.answer.replacingOccurrences(of: "\"w1\"", with: "\"w0\"")
        let twiceValue = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(twice.utf8)))
        #expect(WindowsAnswer.parse(twiceValue, expecting: ["w0", "w1"]) == nil)
    }

    @Test func theStoredAnswerIsParsedAndAThinkingTailIsIgnored() throws {
        let stored = Self.answer + ModelTestJob.thinkingMarker + "some thinking"
        #expect(WindowsAnswer.parse(storedAnswer: stored, expecting: ["w0", "w1"])?.judgements.count == 2)
        #expect(WindowsAnswer.parse(storedAnswer: "nonsense", expecting: ["w0", "w1"]) == nil)
    }

    @Test func theFrontmostRelevantWindowGivesTheCaptureItsKindAndNothingRelevantMeansOther() throws {
        let value = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(Self.answer.utf8)))
        let parsed = try #require(WindowsAnswer.parse(value, expecting: ["w0", "w1"]))
        #expect(parsed.classification(frontToBack: ["w0", "w1"]).kind == .email)
        #expect(parsed.classification(frontToBack: ["w1", "w0"]).kind == .email)
        let none = Self.answer.replacingOccurrences(of: "\"relevant\":true", with: "\"relevant\":false")
        let noneValue = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(none.utf8)))
        let quiet = try #require(WindowsAnswer.parse(noneValue, expecting: ["w0", "w1"]))
        #expect(quiet.classification(frontToBack: ["w0", "w1"]).kind == .other)
        #expect(quiet.classification(frontToBack: ["w0", "w1"]).application == "Outlook")
    }

    // MARK: extraction rule

    @Test func theWindowedExtractionPromptAddsTheRuleAndHasItsOwnVersion() {
        let lines = [RecognisedLine(n: 7, text: "Planning at 10:00", box: PixelBox(x: 10, y: 10, width: 100, height: 18), confidence: 0.9)]
        let windowed = ExtractionPrompts.extractPrompt(kind: .email, lines: lines, pictureSize: (1000, 500), windowed: true).prompt
        let plain = ExtractionPrompts.extractPrompt(kind: .email, lines: lines, pictureSize: (1000, 500)).prompt
        #expect(windowed.contains("These lines are one window of the screen; cite only these line numbers."))
        #expect(!plain.contains("one window of the screen"))
        #expect(ExtractionPrompts.version(for: .email) == "extract-email-v12")
        #expect(ExtractionPrompts.version(for: .email, windowed: true) == "extract-email-v13")
        #expect(windowed.contains("L7 (1%,2%) Planning at 10:00"))
    }
}
