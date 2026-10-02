import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// Comparing a trial over a large library stays quick (spec 008, plan: 1,000 captures under 5 s).
@Suite struct TrialScaleTests {
    @Test func aThousandCapturesAreComparedWithinFiveSeconds() async throws {
        let f = try ReconcileFixture(); defer { f.cleanUp() }
        let reconciler = Reconciler(database: f.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let store = TrialStore(database: f.database, paths: f.base.paths)
        var images = [f.base.imageID]
        for n in 1..<1000 { images.append(try f.addPicture(at: Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 600), display: "D\(n)")) }
        var proposals: [String: [Finding]] = [:]
        for (n, id) in images.enumerated() {
            let day = ReconcileFixture.minutes(n * 1440)
            let findings = (0..<3).map { f.finding("Meeting \(n)-\($0)", start: ReconcileFixture.minutes($0 * 90, after: day), end: ReconcileFixture.minutes($0 * 90 + 30, after: day)) }
            try f.save(findings, imageID: id)
            _ = await reconciler.reconcile(imageID: id)
            // The trial moves the end of the first meeting of every second capture and finds one new meeting in every tenth.
            proposals[id] = findings.enumerated().map { index, finding in
                n % 2 == 0 && index == 0 ? f.finding(finding.title, start: finding.start, end: finding.end?.addingTimeInterval(1800)) : finding
            } + (n % 10 == 0 ? [f.finding("Extra \(n)", start: ReconcileFixture.minutes(600, after: day))] : [])
        }
        // Trial tables are filled directly: the cost being measured is the comparison, not the reading.
        let trial = try store.create(model: "other", promptVersion: "p", think: "off", now: Date())
        for id in images.reversed() {          // the one capture with files is last: saving it finishes the trial
            let result = AnalysisResult(lines: [], classification: ClassificationResult(kind: .email, confidence: 0.9, application: "", platformLook: "", isRemote: false, remoteClient: "", theme: "", calendarName: ""),
                                        findings: proposals[id] ?? [], timezone: TimeZone(identifier: "UTC")!, model: "other", pictureLongEdge: 2048)
            try store.saveProposal(trialID: trial.id, imageID: id, result: result, durationMs: 1, at: Date())
        }
        let began = Date()
        let report = try await TrialComparison(database: f.database, reconciler: reconciler, store: store).report(trialID: trial.id)
        let seconds = Date().timeIntervalSince(began)
        let totals = report.totals
        #expect(totals.changed == 500 && totals.new == 100 && totals.unchanged == 2500, "\(totals)")
        print("trial comparison of 1000 captures: \(seconds) s")
        #expect(seconds < 5, "took \(seconds) s")
    }
}
