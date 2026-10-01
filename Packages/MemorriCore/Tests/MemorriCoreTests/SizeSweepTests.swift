import Foundation
import Testing
@testable import MemorriCore

@Suite struct SizeSweepTests {
    private let start = SyntheticTime.date(2026, 10, 14, 10, 0, zone: "UTC")
    private let names = ["a", "b", "c", "d"]

    private func golden(_ name: String) -> GoldenCase {
        let meta = GoldenMeta(capturedAt: start, macTimezone: "UTC", context: nil, windows: [], displaySize: [100, 100], scale: 1, origin: .synthetic)
        let expected = GoldenExpected(screenKind: "calendar_week", findings: [
            ExpectedFinding(kind: "appointment", title: "Team sync", start: start, end: start.addingTimeInterval(3600), allDay: false, people: [])])
        return GoldenCase(name: name, folder: URL(fileURLWithPath: "/tmp/\(name)"), meta: meta, expected: expected)
    }

    /// `found` cases are matched; of those, `wrongEnd` have their end 30 minutes off; every case takes `seconds`.
    private func results(found: Int, wrongEnd: Int = 0, seconds: Double = 2) -> [String: CaseResult] {
        var table: [String: CaseResult] = [:]
        for (index, name) in names.enumerated() {
            let finding = index < found
                ? [FoundFinding(kind: "appointment", title: "Team sync", start: start, end: start.addingTimeInterval(index < wrongEnd ? 1800 : 3600))]
                : []
            table[name] = CaseResult(kind: "calendar_week", findings: finding, tags: [], contextName: nil, lines: [], seconds: seconds, steps: [])
        }
        return table
    }

    private func sweep(_ bySize: [Int: [String: CaseResult]], busy: Bool = false, used: Used = Used()) -> SizeSweep {
        SizeSweep(runner: { size in
            used.add(size)
            let settings = EvalSettings(model: "m", size: size, think: "off", promptVersions: [:], thresholds: .standard)
            return EvalRunner(analyser: FakeCaseAnalyser(results: bySize[size] ?? [:]), settings: settings, isAppBusy: { busy },
                              serverStatus: { .reachable(version: "0.1") }, now: { Date(timeIntervalSince1970: 0) })
        })
    }

    final class Used: @unchecked Sendable {
        private let lock = NSLock(); private var sizes: [Int] = []
        func add(_ size: Int) { lock.withLock { sizes.append(size) } }
        var value: [Int] { lock.withLock { sizes } }
    }

    private func run(_ bySize: [Int: [String: CaseResult]], sizes: [Int] = [1024, 1536, 2048, 3072]) async throws -> SizeSweepResult {
        try await sweep(bySize).run(cases: names.map(golden), sizes: sizes)
    }

    @Test func everySizeRunsEveryCaseAndGivesItsNumbers() async throws {
        let used = Used()
        let result = try await sweep([1024: results(found: 2, seconds: 1), 1536: results(found: 3, seconds: 2), 2048: results(found: 4, seconds: 4)], used: used)
            .run(cases: names.map(golden), sizes: [1024, 1536, 2048])
        #expect(used.value == [1024, 1536, 2048])
        #expect(result.rows.map(\.size) == [1024, 1536, 2048])
        #expect(result.rows.map(\.cases) == [4, 4, 4])
        #expect(result.rows[0].precision == 1 && result.rows[0].recall == 0.5 && result.rows[2].recall == 1)
        #expect(result.rows[0].meanSeconds == 1 && result.rows[2].meanSeconds == 4)
        #expect(abs(result.rows[0].f1 - 2.0 / 3.0) < 1e-9 && result.rows[2].f1 == 1)
    }

    @Test func theSmallestSizeWithinTwoHundredthsOfTheBestIsRecommended() async throws {
        // 1024 is clearly worse; 1536 equals the best.
        let result = try await run([1024: results(found: 2), 1536: results(found: 4), 2048: results(found: 4), 3072: results(found: 4)])
        #expect(result.recommended == 1536)
    }

    @Test func theDefaultStaysWhenNoSmallerSizeQualifies() async throws {
        let result = try await run([1024: results(found: 1), 1536: results(found: 3), 2048: results(found: 4), 3072: results(found: 4)])
        #expect(result.recommended == 2048 && result.reason.contains("no smaller"))
    }

    @Test func aSizeThatIsOnlyBetterAtTheLargestSizeStillKeepsTheDefaultButSaysSo() async throws {
        let result = try await run([1024: results(found: 1), 1536: results(found: 2), 2048: results(found: 3), 3072: results(found: 4)])
        #expect(result.recommended == 2048 && result.reason.contains("3072"))
    }

    @Test func tiesPreferTheSmallerSize() async throws {
        let same = results(found: 4)
        #expect(try await run([1024: same, 1536: same, 2048: same, 3072: same]).recommended == 1024)
    }

    @Test func fieldAccuracyHasToBeWithinTwoHundredthsToo() async throws {
        // Same findings everywhere, but 1024 gets the end wrong in two cases: it finds everything and is still not good enough.
        let result = try await run([1024: results(found: 4, wrongEnd: 2), 1536: results(found: 4), 2048: results(found: 4), 3072: results(found: 4)])
        #expect(result.rows[0].f1 == 1 && (result.rows[0].fieldAccuracy ?? 1) < 1)
        #expect(result.recommended == 1536)
    }

    @Test func noFindingsAnywhereKeepsTheDefault() async throws {
        let empty = results(found: 0)
        #expect(try await run([1024: empty, 1536: empty, 2048: empty, 3072: empty]).recommended == 2048)
    }

    @Test func theTextShowsATableAndTheRecommendation() async throws {
        let text = try await run([1024: results(found: 2), 1536: results(found: 4), 2048: results(found: 4), 3072: results(found: 4)]).text
        #expect(text.contains("1024") && text.contains("3072") && text.contains("precision") && text.contains("recall") && text.contains("seconds"))
        #expect(text.contains("recommended 1536"))
    }

    @Test func aBusyAppRefusesTheWholeSweep() async {
        await #expect(throws: EvalRefusal.appBusy) {
            try await self.sweep([:], busy: true).run(cases: self.names.map(self.golden), sizes: [1024, 2048])
        }
    }
}
