import Foundation
import Testing
@testable import MemorriCore

@Suite struct EvalReportTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_986_400)

    private func golden(_ name: String, kind: String = "email", origin: GoldenOrigin = .synthetic, findings: [ExpectedFinding]) -> GoldenCase {
        let meta = GoldenMeta(capturedAt: t0, macTimezone: "UTC", context: nil, windows: [], displaySize: [10, 10], scale: 1, origin: origin)
        return GoldenCase(name: name, folder: URL(fileURLWithPath: "/tmp/\(name)"), meta: meta,
                          expected: GoldenExpected(screenKind: kind, tags: [ExpectedTag(key: "application", value: "Mail")], findings: findings))
    }
    private func result(kind: String = "email", _ findings: [FoundFinding], tag: String = "Mail") -> CaseResult {
        CaseResult(kind: kind, findings: findings, tags: [FoundTag(key: "application", value: tag, confidence: 0.9)], contextName: nil,
                   lines: [], seconds: 2, steps: [EvalStepRecord(step: "classify", request: "{}", rawAnswer: "{}", durationMs: 1500)])
    }
    private let settings = EvalSettings(model: "qwen3.8:27b-mlx", size: 2048, think: "off",
                                        promptVersions: ["classify": "classify-v1"], thresholds: .standard)

    private func report(_ items: [(GoldenCase, CaseResult)], busy: Bool = false) -> EvalReport {
        EvalReport.build(settings: settings, cases: items, ranWhileAppBusy: busy, createdAt: t0)
    }
    private var good: (GoldenCase, CaseResult) {
        (golden("email-01", findings: [ExpectedFinding(kind: "task", title: "Send the report", due: t0)]),
         result([FoundFinding(kind: "task", title: "Send the report", due: t0)]))
    }
    private var bad: (GoldenCase, CaseResult) {
        (golden("email-02", findings: [ExpectedFinding(kind: "task", title: "Call the bank", due: t0)]),
         result([FoundFinding(kind: "task", title: "Buy milk", due: t0)], tag: "Outlook"))
    }

    @Test func aReportEncodesToTheDocumentedShapeAndDecodesBack() throws {
        let r = report([good, bad])
        let data = try r.encoded()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1 && json["ranWhileAppBusy"] as? Bool == false)
        let overall = try #require(json["overall"] as? [String: Any])
        for key in ["precision", "recall", "fieldAccuracy", "classificationAccuracy", "meanSeconds"] { #expect(overall[key] != nil, "\(key)") }
        #expect((json["cases"] as? [[String: Any]])?.count == 2)
        #expect(try EvalReport.decode(data) == r)
    }

    @Test func theOverallNumbersFollowTheCases() {
        let r = report([good, bad])
        #expect(r.overall.precision == 0.5 && r.overall.recall == 0.5 && r.overall.classificationAccuracy == 1)
        #expect(r.overall.cases == 2 && r.overall.meanSeconds == 2)
        #expect(r.cases.map(\.name) == ["email-01", "email-02"])
    }

    @Test func comparingTwoReportsGivesTheDifferenceAndNamesChangedCases() {
        let before = report([good, bad])
        let fixed = (bad.0, result([FoundFinding(kind: "task", title: "Call the bank", due: t0)]))
        let after = report([good, fixed])
        let c = EvalReport.compare(before, after)
        #expect(abs(c.precisionDelta - 0.5) < 1e-9 && abs(c.recallDelta - 0.5) < 1e-9)
        #expect(c.changedCases.map(\.name) == ["email-02"])
        #expect(c.text.contains("email-02") && c.text.contains("precision"))
    }

    @Test func comparingAReportWithItselfChangesNothing() {
        let r = report([good, bad])
        let c = EvalReport.compare(r, r)
        #expect(c.changedCases.isEmpty && c.precisionDelta == 0 && c.recallDelta == 0)
    }

    @Test func theTextOutputShowsThresholdsScoresAndTheMissedAndUnexpectedLists() {
        let text = report([good, bad], busy: true).text
        #expect(text.contains("0.80") && text.contains("±5"))
        #expect(text.contains("qwen3.8:27b-mlx") && text.contains("2048") && text.contains("think off"))
        #expect(text.contains("precision 0.50") && text.contains("recall 0.50"))
        #expect(text.contains("email-02") && text.contains("Call the bank") && text.contains("Buy milk"))
        #expect(text.contains("application"))
        #expect(text.contains("ran while the app was busy"))
        #expect(text.contains("synthetic 2") && text.contains("local 0"))
    }

    @Test func aCleanRunDoesNotMentionBusyOrMisses() {
        let text = report([good]).text
        #expect(!text.contains("ran while the app was busy") && !text.contains("missed"))
    }

    @Test func aReportWithLocalCasesRefusesToBeWrittenUnderTheTrackedSyntheticFolder() throws {
        let temp = TempDirectory(); defer { temp.cleanUp() }
        let local = (golden("mine", origin: .local, findings: []), result([]))
        let tracked = temp.url.appendingPathComponent("eval/golden/synthetic/run.json")
        #expect(throws: EvalReportError.self) { try report([local]).write(to: tracked) }
        let ignored = temp.url.appendingPathComponent("eval/out/run.json")
        try report([local]).write(to: ignored)
        #expect(FileManager.default.fileExists(atPath: ignored.path))
        try report([good]).write(to: temp.url.appendingPathComponent("eval/golden/synthetic/ok.json"))
    }
}
