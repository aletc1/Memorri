import Foundation
import Testing
@testable import MemorriCore

@Suite struct SequenceCaseTests {
    private let json = """
    {
      "macTimezone": "Europe/Madrid",
      "contexts": [{"id": "A", "name": "Customer A", "timezone": "Europe/Madrid"}],
      "captures": [
        {"id": "c1", "capturedAt": "2026-10-13T08:00:00Z", "context": "A",
         "findings": [{"event": "standup-tue", "kind": "appointment", "title": "Daily standup", "lang": "en",
                       "start": "2026-10-14T07:00:00Z", "end": "2026-10-14T07:15:00Z", "allDay": false,
                       "inferred": ["end"], "confidence": 0.8}]},
        {"id": "c2", "capturedAt": "2026-10-13T09:00:00Z",
         "findings": [{"event": "report", "kind": "task", "title": "Send the report", "due": "2026-10-15T10:00:00Z"}]}
      ],
      "actions": [{"after": "c2", "action": "dismiss", "event": "standup-tue"},
                  {"after": "c2", "action": "editTitle", "event": "report", "title": "Report for Anna"}]
    }
    """

    private func decode(_ text: String, name: String = "case") throws -> SequenceCase { try SequenceCase.decode(Data(text.utf8), name: name) }

    @Test func aCaseDecodesWithContextsCapturesFindingsAndActions() throws {
        let c = try decode(json, name: "standup")
        #expect(c.name == "standup" && c.macTimezone == "Europe/Madrid")
        #expect(c.contexts == [SequenceCase.ContextSpec(id: "A", name: "Customer A", timezone: "Europe/Madrid")])
        #expect(c.captures.map(\.id) == ["c1", "c2"] && c.captures[0].context == "A" && c.captures[1].context == nil)
        let first = c.captures[0].findings[0]
        #expect(first.event == "standup-tue" && first.kind == .appointment && first.lang == "en" && first.inferred == ["end"] && first.confidence == 0.8)
        #expect(first.start == Date(timeIntervalSince1970: 1_791_961_200) && first.end == Date(timeIntervalSince1970: 1_791_962_100) && !first.allDay)
        let task = c.captures[1].findings[0]
        #expect(task.kind == .task && task.due == Date(timeIntervalSince1970: 1_792_058_400) && task.start == nil && task.confidence == 0.9 && task.inferred.isEmpty)
        #expect(c.actions == [SequenceCase.Action(after: "c2", action: .dismiss, event: "standup-tue", title: nil),
                              SequenceCase.Action(after: "c2", action: .editTitle, event: "report", title: "Report for Anna")])
    }

    @Test func actionsAreOptional() throws {
        let c = try decode(#"{"macTimezone":"UTC","contexts":[],"captures":[]}"#)
        #expect(c.actions.isEmpty && c.captures.isEmpty)
    }

    @Test func aFindingWithoutAnEventIsRejectedWithAClearMessage() {
        let text = json.replacingOccurrences(of: #""event": "report", "#, with: "")
        #expect(throws: SequenceCaseError.self) { try decode(text, name: "broken") }
        do { _ = try decode(text, name: "broken") } catch { #expect("\(error)".contains("broken") && "\(error)".contains("event")) }
    }

    @Test func anUnknownActionOrKindIsRejected() {
        #expect(throws: SequenceCaseError.self) { try decode(json.replacingOccurrences(of: "\"dismiss\"", with: "\"teleport\"")) }
        #expect(throws: SequenceCaseError.self) { try decode(json.replacingOccurrences(of: "\"task\"", with: "\"meeting\"")) }
    }

    @Test func anActionOrFindingThatNamesAnUnknownCaptureOrContextIsRejected() {
        #expect(throws: SequenceCaseError.self) { try decode(json.replacingOccurrences(of: "\"after\": \"c2\", \"action\": \"dismiss\"", with: "\"after\": \"c9\", \"action\": \"dismiss\"")) }
        #expect(throws: SequenceCaseError.self) { try decode(json.replacingOccurrences(of: "\"context\": \"A\"", with: "\"context\": \"Z\"")) }
        #expect(throws: SequenceCaseError.self) { try decode(json.replacingOccurrences(of: "\"title\": \"Report for Anna\"", with: "\"x\": 1")) }
    }

    @Test func encodingIsStableAndRoundTrips() throws {
        let c = try decode(json)
        let a = try c.encoded(), b = try c.encoded()
        #expect(a == b)
        #expect(try SequenceCase.decode(a, name: "case") == c)
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.contains("2026-10-14T07:00:00Z") && !text.contains("\\/"))
    }

    @Test func loadAllReadsEveryFolderWithASequenceFileInOrder() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        for name in ["b-case", "a-case"] {
            let folder = temp.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("sequence.json"))
        }
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("not-a-case"), withIntermediateDirectories: true)
        let cases = try SequenceCase.loadAll(in: temp.url)
        #expect(cases.map(\.name) == ["a-case", "b-case"])
        #expect(throws: SequenceCaseError.self) { try SequenceCase.loadAll(in: temp.url.appendingPathComponent("missing")) }
    }
}
