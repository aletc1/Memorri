import Foundation
import Testing
@testable import MemorriCore

@Suite struct ClassificationTests {
    static let goodAnswer = """
    {"screen_kind":"calendar_week","kind_confidence":0.93,"application":"Outlook","platform_look":"windows",
     "remote_session":{"is_remote":true,"client":"Citrix"},"theme":"light","calendar_name":"Customer A"}
    """

    private func validate(_ text: String) -> Result<JSONValue, SchemaValidationError> {
        SchemaValidator.validate(text, against: ExtractionSchemas.classifySchema)
    }

    @Test func thereAreSevenKindsAndOthersAreRejected() {
        #expect(ScreenKind.allCases.map(\.rawValue) == ["calendar_month", "calendar_week", "calendar_day", "email", "chat", "document", "other"])
        #expect(ScreenKind(rawValue: "spreadsheet") == nil)
        #expect(ScreenKind(rawValue: "") == nil)
    }

    @Test func theSchemaAcceptsAGoodAnswer() {
        if case .failure(let error) = validate(Self.goodAnswer) { Issue.record("rejected: \(error)") }
    }

    @Test func theSchemaRejectsABadAnswer() {
        let noKind = #"{"kind_confidence":0.9,"application":"","platform_look":"","remote_session":{"is_remote":false,"client":""},"theme":"","calendar_name":""}"#
        let unknownKind = Self.goodAnswer.replacingOccurrences(of: "calendar_week", with: "spreadsheet")
        let textConfidence = Self.goodAnswer.replacingOccurrences(of: "0.93", with: "\"high\"")
        let noRemoteFlag = Self.goodAnswer.replacingOccurrences(of: "\"is_remote\":true,", with: "")
        for bad in [noKind, unknownKind, textConfidence, noRemoteFlag, "not json"] {
            if case .success = validate(bad) { Issue.record("accepted: \(bad)") }
        }
    }

    @Test func thePromptNamesEverySevenKindAndEveryVisualFact() {
        let prompt = ExtractionPrompts.classifyPrompt()
        for kind in ScreenKind.allCases { #expect(prompt.contains(kind.rawValue), Comment(rawValue: kind.rawValue)) }
        for word in ["application", "macos", "windows", "linux", "remote", "theme", "calendar name"] {
            #expect(prompt.lowercased().contains(word), Comment(rawValue: word))
        }
        #expect(ExtractionPrompts.classifyVersion == "classify-v2")
    }

    @Test func anAnswerBecomesAClassification() throws {
        let value = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(Self.goodAnswer.utf8)))
        let c = try #require(ClassificationResult.parse(value))
        #expect(c.kind == .calendarWeek && c.confidence == 0.93)
        #expect(c.application == "Outlook" && c.platformLook == "windows" && c.theme == "light" && c.calendarName == "Customer A")
        #expect(c.isRemote && c.remoteClient == "Citrix")
    }

    @Test func aStoredAnswerWithThinkingTextStillParses() throws {
        let stored = Self.goodAnswer + ModelTestJob.thinkingMarker + "it looks like a week view"
        #expect(ClassificationResult.parse(storedAnswer: stored)?.kind == .calendarWeek)
        #expect(ClassificationResult.parse(storedAnswer: "garbage") == nil)
        #expect(ClassificationResult.parse(storedAnswer: #"{"screen_kind":"chat"}"#) == nil)
    }

    @Test func anUnsureAnswerBecomesOther() throws {
        let value = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(Self.goodAnswer.utf8)))
        let unsure = try #require(ClassificationResult.parse(value)?.withConfidence(0.4))
        let resolved = unsure.resolved(threshold: 0.5)
        #expect(resolved.kind == .other && resolved.modelKind == .calendarWeek && resolved.confidence == 0.4)
        #expect(unsure.withConfidence(0.5).resolved(threshold: 0.5).kind == .calendarWeek)
        #expect(ClassificationResult.defaultThreshold == 0.5)
    }
}
