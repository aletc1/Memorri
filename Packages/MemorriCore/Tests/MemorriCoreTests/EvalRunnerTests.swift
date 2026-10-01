import Foundation
import Testing
@testable import MemorriCore

final class FakeCaseAnalyser: CaseAnalysing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(name: String, replaying: [EvalStepRecord]?)] = []
    private let results: [String: CaseResult]
    private let failing: Set<String>

    init(results: [String: CaseResult], failing: Set<String> = []) { self.results = results; self.failing = failing }

    var names: [String] { lock.withLock { calls.map(\.name) } }
    var replays: [[EvalStepRecord]?] { lock.withLock { calls.map(\.replaying) } }

    private func record(_ name: String, _ replaying: [EvalStepRecord]?) {
        lock.withLock { calls.append((name, replaying)) }
    }

    func analyse(_ golden: GoldenCase, replaying steps: [EvalStepRecord]?) async throws -> CaseResult {
        record(golden.name, steps)
        if failing.contains(golden.name) { throw PipelineError.transient("scripted failure") }
        return results[golden.name] ?? CaseResult(kind: "other", findings: [], tags: [], contextName: nil, lines: [], seconds: 0, steps: [])
    }
}

@Suite struct EvalRunnerTests {
    private let settings = EvalSettings(model: "m", size: 2048, think: "off", promptVersions: ["classify": "v1"], thresholds: .standard)
    private let start = SyntheticTime.date(2026, 10, 14, 10, 0, zone: "UTC")

    private func golden(_ name: String, origin: GoldenOrigin = .synthetic, title: String = "Team sync") -> GoldenCase {
        let meta = GoldenMeta(capturedAt: start, macTimezone: "UTC", context: nil, windows: [], displaySize: [100, 100], scale: 1, origin: origin)
        let expected = GoldenExpected(screenKind: "calendar_week",
                                      findings: [ExpectedFinding(kind: "appointment", title: title, start: start, end: start.addingTimeInterval(3600), allDay: false, people: [])])
        return GoldenCase(name: name, folder: URL(fileURLWithPath: "/tmp/\(name)"), meta: meta, expected: expected)
    }

    private func perfect(_ title: String = "Team sync", step: String = "classify") -> CaseResult {
        CaseResult(kind: "calendar_week",
                   findings: [FoundFinding(kind: "appointment", title: title, start: start, end: start.addingTimeInterval(3600))],
                   tags: [], contextName: nil, lines: [], seconds: 2,
                   steps: [EvalStepRecord(step: step, request: "{}", rawAnswer: "{\"a\":1}", durationMs: 2000)])
    }

    private func runner(_ analyser: FakeCaseAnalyser, busy: Bool = false, status: ServerStatus = .reachable(version: "0.1")) -> EvalRunner {
        EvalRunner(analyser: analyser, settings: settings, isAppBusy: { busy }, serverStatus: { status }, now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func runsAndScoresEveryCase() async throws {
        let analyser = FakeCaseAnalyser(results: ["a": perfect(), "b": perfect("Something else")])
        let report = try await runner(analyser).run(cases: [golden("a"), golden("b")])
        #expect(analyser.names == ["a", "b"])
        #expect(report.cases.map(\.name) == ["a", "b"])
        #expect(report.overall.cases == 2)
        #expect(report.cases[0].precision == 1)
        #expect(report.cases[1].precision == 0)
        #expect(report.settings == settings)
        #expect(report.ranWhileAppBusy == false)
    }

    @Test func onlyRunsTheNamedCase() async throws {
        let analyser = FakeCaseAnalyser(results: ["a": perfect(), "b": perfect()])
        let report = try await runner(analyser).run(cases: [golden("a"), golden("b")], only: "b")
        #expect(analyser.names == ["b"])
        #expect(report.cases.map(\.name) == ["b"])
        await #expect(throws: EvalRefusal.unknownCase("zzz")) { try await runner(analyser).run(cases: [golden("a")], only: "zzz") }
    }

    @Test func noCasesIsARefusal() async {
        let analyser = FakeCaseAnalyser(results: [:])
        await #expect(throws: EvalRefusal.noCases) { try await runner(analyser).run(cases: []) }
    }

    @Test func aFailedCaseCountsAsNothingFoundAndTheRunGoesOn() async throws {
        let analyser = FakeCaseAnalyser(results: ["b": perfect()], failing: ["a"])
        let report = try await runner(analyser).run(cases: [golden("a"), golden("b")])
        #expect(report.cases[0].recall == 0)
        #expect(report.cases[0].foundKind == "failed")
        #expect(report.cases[1].recall == 1)
    }

    @Test func busyStopsBeforeAnyCaseUnlessAllowed() async throws {
        let analyser = FakeCaseAnalyser(results: ["a": perfect()])
        await #expect(throws: EvalRefusal.appBusy) { try await runner(analyser, busy: true).run(cases: [golden("a")]) }
        #expect(analyser.names.isEmpty)
        let allowed = try await runner(analyser, busy: true).run(cases: [golden("a")], allowBusy: true)
        #expect(allowed.ranWhileAppBusy)
        let idle = try await runner(analyser, busy: false).run(cases: [golden("a")], allowBusy: true)
        #expect(idle.ranWhileAppBusy == false)
    }

    @Test func anUnusableServerStopsWithTheStatusText() async {
        let analyser = FakeCaseAnalyser(results: ["a": perfect()])
        await #expect(throws: EvalRefusal.serverUnavailable(ServerStatus.notReachable.message)) {
            try await runner(analyser, status: .notReachable).run(cases: [golden("a")])
        }
        #expect(analyser.names.isEmpty)
    }

    @Test func replayRescoresStoredAnswersWithoutTheServerOrTheBusyCheck() async throws {
        let first = FakeCaseAnalyser(results: ["a": perfect(), "b": perfect()])
        let stored = try await runner(first).run(cases: [golden("a"), golden("b")])

        let again = FakeCaseAnalyser(results: ["a": perfect(), "b": perfect()])
        let replay = try await runner(again, busy: true, status: .notReachable).run(cases: [golden("a"), golden("b", title: "Changed")], replay: stored)
        #expect(again.names == ["a", "b"])
        #expect(again.replays.allSatisfy { $0 == stored.cases[0].steps })
        #expect(replay.cases[0].recall == 1)
        #expect(replay.cases[1].recall == 0, "the edited expectation is scored against the stored answer")
        #expect(replay.ranWhileAppBusy == false)
    }

    @Test func replayOnlyRunsCasesThatAreInTheStoredReport() async throws {
        let first = FakeCaseAnalyser(results: ["a": perfect()])
        let stored = try await runner(first).run(cases: [golden("a")])
        let again = FakeCaseAnalyser(results: ["a": perfect(), "b": perfect()])
        let replay = try await runner(again).run(cases: [golden("a"), golden("b")], replay: stored)
        #expect(again.names == ["a"])
        #expect(replay.cases.map(\.name) == ["a"])
        await #expect(throws: EvalRefusal.noCases) { try await runner(again).run(cases: [golden("c")], replay: stored) }
    }

    @Test func localAndSyntheticResultsAreSeparated() async throws {
        let analyser = FakeCaseAnalyser(results: ["s": perfect(), "l": perfect("Nope")])
        let report = try await runner(analyser).run(cases: [golden("s"), golden("l", origin: .local)])
        #expect(report.cases.map(\.origin) == ["synthetic", "local"])
        #expect(report.summary.byOrigin["synthetic"]?.precision == 1)
        #expect(report.summary.byOrigin["local"]?.precision == 0)
        #expect(report.text.contains("synthetic 1"))
        #expect(report.text.contains("local 1"))
    }
}
