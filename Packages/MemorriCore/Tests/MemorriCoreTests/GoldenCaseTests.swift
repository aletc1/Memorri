import Foundation
import Testing
@testable import MemorriCore

@Suite struct GoldenCaseTests {
    private let meta = """
    { "capturedAt": "2026-10-14T23:40:00Z", "macTimezone": "Europe/Madrid",
      "context": { "name": "Customer A", "timezone": "America/New_York", "hints": [ { "kind": "app", "value": "Outlook" } ] },
      "windows": [ { "app": "Microsoft Outlook", "bundleID": "com.microsoft.Outlook", "title": "Calendar", "frame": [0, 0, 1600, 1000] } ],
      "displaySize": [1600, 1000], "scale": 1.0, "origin": "synthetic" }
    """
    private let expected = """
    { "screenKind": "calendar_week",
      "tags": [ { "key": "application", "value": "Outlook" } ],
      "context": "Customer A",
      "lines": [ { "text": "Team sync", "box": [10, 20, 100, 30] }, { "text": "Mon 12" } ],
      "findings": [
        { "kind": "appointment", "title": "Team sync", "start": "2026-10-14T10:00:00-04:00", "end": "2026-10-14T11:30:00-04:00",
          "allDay": false, "people": ["Anna"], "place": "Room 1", "inferred": ["end"] },
        { "kind": "task", "title": "Send the report", "due": "2026-10-16T00:00:00Z" } ] }
    """

    private func makeCase(_ root: URL, name: String = "week-01", meta: String? = nil, expected: String? = nil, picture: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if picture { try Data([0x89, 0x50]).write(to: folder.appendingPathComponent("screenshot.png")) }
        if let meta = meta ?? Optional(self.meta) { try Data(meta.utf8).write(to: folder.appendingPathComponent("meta.json")) }
        if let expected = expected ?? Optional(self.expected) { try Data(expected.utf8).write(to: folder.appendingPathComponent("expected.json")) }
        return folder
    }

    @Test func aCaseFolderLoads() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let folder = try makeCase(temp.url)
        let golden = try GoldenCase.load(folder: folder)
        #expect(golden.name == "week-01" && golden.origin == .synthetic)
        #expect(golden.pictureURL.lastPathComponent == "screenshot.png")
        #expect(golden.meta.macTimezone == "Europe/Madrid" && golden.meta.displaySize == [1600, 1000] && golden.meta.scale == 1.0)
        #expect(golden.meta.capturedAt == Date(timeIntervalSince1970: 1_792_021_200))
        #expect(golden.meta.context?.name == "Customer A" && golden.meta.context?.timezone == "America/New_York")
        #expect(golden.meta.context?.hints == [GoldenHint(kind: "app", value: "Outlook")])
        #expect(golden.meta.windows.first == GoldenWindow(app: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", title: "Calendar", frame: [0, 0, 1600, 1000]))
        #expect(golden.expected.screenKind == "calendar_week" && golden.expected.context == "Customer A")
        #expect(golden.expected.tags == [ExpectedTag(key: "application", value: "Outlook")])
        #expect(golden.expected.lines?.first == ExpectedLine(text: "Team sync", box: [10, 20, 100, 30]))
        #expect(golden.expected.lines?.last == ExpectedLine(text: "Mon 12", box: nil))
        let finding = try #require(golden.expected.findings.first)
        #expect(finding.kind == "appointment" && finding.title == "Team sync" && finding.people == ["Anna"] && finding.place == "Room 1")
        #expect(finding.start == Date(timeIntervalSince1970: 1_791_986_400) && finding.end == Date(timeIntervalSince1970: 1_791_991_800))
        #expect(finding.inferred == ["end"] && finding.allDay == false)
        #expect(golden.expected.findings[1].due != nil && golden.expected.findings[1].start == nil)
    }

    @Test func writingThenLoadingGivesTheSameCase() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let source = try GoldenCase.load(folder: try makeCase(temp.url))
        let out = temp.url.appendingPathComponent("copy", isDirectory: true)
        try source.write(to: out, picture: Data([0x89, 0x50]))
        let again = try GoldenCase.load(folder: out)
        #expect(again.meta == source.meta && again.expected == source.expected && again.origin == source.origin)
        #expect(try Data(contentsOf: out.appendingPathComponent("screenshot.png")) == Data([0x89, 0x50]))
    }

    @Test func writingTwiceGivesTheSameBytes() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let source = try GoldenCase.load(folder: try makeCase(temp.url))
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        try source.write(to: a, picture: Data([1, 2, 3])); try source.write(to: b, picture: Data([1, 2, 3]))
        for file in ["meta.json", "expected.json", "screenshot.png"] {
            #expect(try Data(contentsOf: a.appendingPathComponent(file)) == Data(contentsOf: b.appendingPathComponent(file)))
        }
    }

    @Test func aMissingFileNamesTheCase() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let folder = try makeCase(temp.url, name: "broken-02")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("expected.json"))
        do { _ = try GoldenCase.load(folder: folder); Issue.record("expected an error") } catch {
            #expect("\(error)".contains("broken-02") && "\(error)".contains("expected.json"))
        }
    }

    @Test func anUnknownScreenKindNamesTheCase() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let folder = try makeCase(temp.url, name: "odd-03", expected: #"{ "screenKind": "spreadsheet", "findings": [] }"#)
        do { _ = try GoldenCase.load(folder: folder); Issue.record("expected an error") } catch {
            #expect("\(error)".contains("odd-03") && "\(error)".contains("spreadsheet"))
        }
    }

    @Test func aFolderWithoutAPictureIsSkippedWithAWarning() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        _ = try makeCase(temp.url, name: "good-01")
        _ = try makeCase(temp.url, name: "nopic-02", picture: false)
        let result = try GoldenCase.loadAll(in: temp.url)
        #expect(result.cases.map(\.name) == ["good-01"])
        #expect(result.warnings.count == 1 && result.warnings[0].contains("nopic-02"))
    }

    @Test func casesAreFoundInSubfoldersInNameOrder() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let set = temp.url.appendingPathComponent("synthetic", isDirectory: true)
        _ = try makeCase(set, name: "b-case"); _ = try makeCase(set, name: "a-case")
        _ = try makeCase(temp.url, name: "local-case")
        let result = try GoldenCase.loadAll(in: temp.url)
        #expect(result.cases.map(\.name) == ["a-case", "b-case", "local-case"])
    }

    @Test func originDefaultsToLocalAndMinimalFilesLoad() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let folder = try makeCase(temp.url, meta: #"{ "capturedAt": "2026-10-14T10:00:00Z", "macTimezone": "UTC", "displaySize": [100, 50], "scale": 2 }"#,
                                  expected: #"{ "screenKind": "other", "findings": [] }"#)
        let golden = try GoldenCase.load(folder: folder)
        #expect(golden.origin == .local && golden.meta.windows.isEmpty && golden.meta.context == nil)
        #expect(golden.expected.tags == nil && golden.expected.lines == nil && golden.expected.findings.isEmpty)
    }
}
