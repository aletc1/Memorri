import Foundation
import Testing
@testable import MemorriCore

@Suite struct PromptsSchemasTests {
    private let good = #"{"findings":[{"kind":"appointment","title":"Team sync","cited_lines":[3],"start_text":"10:00","all_day":false,"people":["Ana"]}]}"#

    private func validate(_ text: String, _ kind: ScreenKind) -> Result<JSONValue, SchemaValidationError> {
        SchemaValidator.validate(text, against: ExtractionSchemas.extractSchema(for: kind))
    }

    private func line(_ n: Int, x: Int = 100, y: Int = 50, w: Int = 200, h: Int = 20, text: String = "text") -> RecognisedLine {
        RecognisedLine(n: n, text: text, box: PixelBox(x: x, y: y, width: w, height: h), confidence: 0.9)
    }

    @Test func everyKindHasVersionedPromptAndSchema() {
        for kind in ScreenKind.allCases {
            #expect(ExtractionPrompts.version(for: kind) == "extract-\(kind.rawValue)-v12")
            #expect(ExtractionSchemas.schemaVersion(for: kind) == "schema-\(kind.rawValue)-\(kind == .calendarMonth ? "v2" : "v1")")
        }
    }

    @Test func everySchemaAcceptsAGoodAnswerAndAnEmptyList() {
        for kind in ScreenKind.allCases {
            if case .failure(let error) = validate(good, kind) { Issue.record("\(kind): \(error)") }
            if case .failure(let error) = validate(#"{"findings":[]}"#, kind) { Issue.record("\(kind) empty: \(error)") }
        }
    }

    @Test func everySchemaRejectsABadFinding() {
        let noCitation = #"{"findings":[{"kind":"task","title":"x"}]}"#
        let emptyTitle = #"{"findings":[{"kind":"task","title":"","cited_lines":[1]}]}"#
        let unknownKind = #"{"findings":[{"kind":"meeting","title":"x","cited_lines":[1]}]}"#
        let noList = #"{"items":[]}"#
        for kind in ScreenKind.allCases {
            for bad in [noCitation, emptyTitle, unknownKind, noList] {
                if case .success = validate(bad, kind) { Issue.record("\(kind) accepted \(bad)") }
            }
        }
    }

    @Test func aFindingThatCitesNothingIsLeftToTheCitationCheck() {
        if case .failure(let error) = validate(#"{"findings":[{"kind":"task","title":"x","cited_lines":[]}]}"#, .document) { Issue.record("\(error)") }
    }

    @Test func extraFieldsBelongToTheKindsThatNeedThem() {
        func properties(_ kind: ScreenKind) -> Set<String> {
            guard case .object(let root) = ExtractionSchemas.extractSchema(for: kind), case .object(let top)? = root["properties"],
                  case .object(let findings)? = top["findings"], case .object(let items)? = findings["items"],
                  case .object(let props)? = items["properties"] else { return [] }
            return Set(props.keys)
        }
        for kind in [ScreenKind.calendarWeek, .calendarDay, .calendarMonth] { #expect(properties(kind).contains("column_line")) }
        #expect(properties(.email).contains("sent_text"))
        #expect(properties(.chat).contains("message_time_text"))
        #expect(!properties(.document).contains("column_line") && !properties(.document).contains("sent_text"))
        #expect(!properties(.email).contains("message_time_text"))
        for kind in ScreenKind.allCases {
            for key in ["kind", "title", "cited_lines", "start_text", "end_text", "date_text", "due_text", "remind_text", "all_day", "people", "place", "notes"] {
                #expect(properties(kind).contains(key), Comment(rawValue: "\(kind) \(key)"))
            }
        }
    }

    @Test func thePromptGivesTheRulesAndTheLines() {
        let lines = [line(1, text: "Mon 12"), line(2, text: "Team sync")]
        for kind in ScreenKind.allCases {
            let (prompt, capped) = ExtractionPrompts.extractPrompt(kind: kind, lines: lines, pictureSize: (1000, 500))
            let lower = prompt.lowercased()
            #expect(lower.contains("never invent anything"), Comment(rawValue: "\(kind)"))
            #expect(lower.contains("cited_lines"))
            #expect(lower.contains("exactly as written"))
            #expect(lower.contains("2 to 5 words") && lower.contains("no dates, times or line numbers"))
            #expect(lower.contains("skip everything else") && lower.contains("never a sentence"))
            #expect(prompt.contains("start_text") && prompt.contains("due_text") && prompt.contains("date_text"))
            #expect(prompt.contains("Lines:\nL1 (10%,10%) Mon 12\nL2 (10%,10%) Team sync"))
            #expect(!capped)
        }
    }

    @Test func theExamplesAreForScreensWhoseDatesAreWrittenInText() {
        func prompt(_ kind: ScreenKind) -> String { ExtractionPrompts.extractPrompt(kind: kind, lines: [line(1)], pictureSize: (100, 100)).prompt }
        for kind in [ScreenKind.document, .email, .chat, .other] { #expect(prompt(kind).contains("Examples (lines, then the answer)"), Comment(rawValue: "\(kind)")) }
        for kind in [ScreenKind.calendarWeek, .calendarDay, .calendarMonth] { #expect(!prompt(kind).contains("Examples"), Comment(rawValue: "\(kind)")) }
    }

    @Test func kindSpecificHintsAreOnlyInTheirPrompts() {
        func prompt(_ kind: ScreenKind) -> String { ExtractionPrompts.extractPrompt(kind: kind, lines: [line(1)], pictureSize: (100, 100)).prompt.lowercased() }
        #expect(prompt(.calendarWeek).contains("column_line") && prompt(.calendarDay).contains("column_line") && prompt(.calendarMonth).contains("column_line"))
        #expect(prompt(.email).contains("sent_text") && prompt(.email).contains("open message"))
        #expect(prompt(.calendarWeek).contains("is an appointment") && prompt(.calendarMonth).contains("day number"))
        #expect(prompt(.chat).contains("message_time_text"))
        #expect(!prompt(.document).contains("column_line") && !prompt(.other).contains("sent_text"))
    }

    @Test func positionsArePercentagesOfThePictureRoundedDown() {
        let text = ExtractionPrompts.extractPrompt(kind: .document, lines: [line(1, x: 333, y: 499, w: 10, h: 10, text: "a")], pictureSize: (1000, 500)).prompt
        #expect(text.contains("L1 (33%,99%) a"))
    }

    @Test func moreThan600LinesAreCappedDroppingTheSmallestBoxesFirst() {
        var lines = (1...650).map { line($0, w: 100 + $0, h: 20, text: "t\($0)") }
        lines[9] = line(10, w: 1, h: 1, text: "tiny")          // the smallest box
        let (prompt, capped) = ExtractionPrompts.extractPrompt(kind: .document, lines: lines, pictureSize: (1000, 500))
        #expect(capped)
        let numbered = (prompt.components(separatedBy: "Lines:\n").last ?? "").split(separator: "\n").filter { $0.hasPrefix("L") && $0.contains("%,") }
        #expect(numbered.count == ExtractionPrompts.maxLines)
        #expect(!prompt.contains(") tiny"))
        #expect(prompt.contains("L650 "))
        // The kept lines stay in reading order and keep their own numbers.
        let ns = numbered.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) }
        #expect(ns == ns.sorted())
    }

    @Test func exactly600LinesAreNotCapped() {
        let lines = (1...600).map { line($0) }
        #expect(!ExtractionPrompts.extractPrompt(kind: .document, lines: lines, pictureSize: (100, 100)).capApplied)
    }
}
