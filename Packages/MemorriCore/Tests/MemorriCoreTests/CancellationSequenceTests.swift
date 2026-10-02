import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Scores the detector on seeded sequences of daily calendar captures with known cancellations (spec 010 SC-001, SC-003).
@Suite struct CancellationSequenceTests {
    private let day: TimeInterval = 86_400
    private let titles = ["Standup", "Budget review", "Design sync", "Customer call", "Retro", "Planning", "Interview", "Lunch talk"]

    /// A small deterministic generator so every run sees the same sequences.
    private struct Seeded { var state: UInt64
        mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

    private struct Outcome { var cancelled = 0, flaggedCancelled = 0, flagged = 0, wrongFlags = 0, absencesFromNonCalendar = 0, hiddenFlags = 0 }

    private func spans(_ fromMinutes: Int, _ toMinutes: Int) -> [DateInterval] {
        [DateInterval(start: ReconcileFixture.minutes(fromMinutes), end: ReconcileFixture.minutes(toMinutes))]
    }

    /// One sequence: 8 meetings on the same day of the week view, captured on 7 successive days.
    /// - meetings 0...1 are cancelled after the second capture (absent from capture 2 on),
    /// - meeting 7 is at the bottom of the grid and scrolled out of view in the last two captures (5 and 6; it would be flagged if the covered time were ignored),
    /// - meeting 5 is missing from exactly one capture (a glitch: must not be flagged),
    /// - capture 3 is a mail window (no coverage, nothing shown) and capture 4 has no context.
    private func run(seed: UInt64, withCoverage: Bool = true) async throws -> Outcome {
        var random = Seeded(state: seed)
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        try f.addContext("ctx-a", "Customer A")
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let detector = CancellationDetector(database: f.database, now: { Date(timeIntervalSince1970: 1_800_100_000) })
        // Cancelled: two meetings chosen by the seed (never 5 or 7, which are the glitch and the scrolled one).
        var cancelled = Set<Int>()
        while cancelled.count < 2 { cancelled.insert(random.next(5)) }
        let glitchCapture = 2 + random.next(4)

        var outcome = Outcome(); outcome.cancelled = cancelled.count
        for capture in 0..<7 {
            let image = try f.addPicture(at: ReconcileFixture.nine.addingTimeInterval(Double(capture) * day))
            let mail = capture == 3, noContext = capture == 4, scrolled = (5...6).contains(capture)
            var shown: [Int] = []
            if !mail {
                for index in 0..<8 {
                    if capture >= 2, cancelled.contains(index) { continue }
                    if index == 5, capture == glitchCapture { continue }
                    if index == 7, scrolled { continue }
                    shown.append(index)
                }
            }
            try f.save(shown.map { f.finding(titles[$0], start: ReconcileFixture.minutes($0 * 60), end: ReconcileFixture.minutes($0 * 60 + 45)) },
                       imageID: image, contextID: noContext ? nil : "ctx-a")
            _ = await reconciler.reconcile(imageID: image)
            // The grid shows 07:00 to 15:00, or only up to 13:00 when scrolled; a mail window has no calendar coverage at all.
            let coverage: [CoverageDraft] = mail || !withCoverage ? [] : [CoverageDraft(windowKey: "w0", kind: .calendarWeek, spans: spans(scrolled ? -30 : -30, scrolled ? 6 * 60 + 15 : 8 * 60 + 15))]
            _ = try detector.record(imageID: image, coverage: coverage)
            if mail { outcome.absencesFromNonCalendar += try f.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cancel_absences WHERE image_id = ?", arguments: [image]) ?? 0 } }
        }
        let flaggedTitles = try f.read { try String.fetchAll($0, sql: "SELECT title FROM items WHERE review_reasons_json LIKE '%possibly-cancelled%'") }
        let cancelledTitles = Set(cancelled.map { titles[$0] })
        outcome.flagged = flaggedTitles.count
        outcome.flaggedCancelled = flaggedTitles.filter(cancelledTitles.contains).count
        outcome.wrongFlags = flaggedTitles.filter { !cancelledTitles.contains($0) }.count
        outcome.hiddenFlags = flaggedTitles.filter { $0 == titles[7] || $0 == titles[5] }.count
        return outcome
    }

    @Test func cancellationsAreFoundAndFalseFlagsStayRare() async throws {
        var total = Outcome()
        for seed in 1...12 {
            let one = try await run(seed: UInt64(seed) * 7919)
            total.cancelled += one.cancelled; total.flaggedCancelled += one.flaggedCancelled; total.flagged += one.flagged
            total.wrongFlags += one.wrongFlags; total.absencesFromNonCalendar += one.absencesFromNonCalendar; total.hiddenFlags += one.hiddenFlags
        }
        #expect(total.cancelled == 24)
        #expect(Double(total.flaggedCancelled) / Double(total.cancelled) >= 0.9)                           // SC-001: recall
        #expect(total.flagged > 0 && Double(total.wrongFlags) / Double(total.flagged) <= 0.05)              // SC-001: at most 1 in 20 flags is wrong
        #expect(total.absencesFromNonCalendar == 0 && total.hiddenFlags == 0)                                // SC-003: scrolled out, glitches and non-calendar captures
    }

    @Test func withoutCoverageNothingIsEverFlagged() async throws {
        for seed in 1...4 {
            let one = try await run(seed: UInt64(seed) * 104729, withCoverage: false)
            #expect(one.flagged == 0 && one.absencesFromNonCalendar == 0)
        }
    }
}
