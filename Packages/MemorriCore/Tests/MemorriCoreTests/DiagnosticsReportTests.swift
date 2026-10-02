import Foundation
import GRDB
import Testing
@testable import MemorriCore

/// The diagnostics report carries figures and sanitised log lines, never the library's content (spec 010 FR-023 to FR-026, SC-008).
@Suite struct DiagnosticsReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    /// Strings that must never appear anywhere in a report.
    private let planted = ["Zorblax", "Quux Tower", "Maximilian Quibble", "Wombat invoice", "Acme Zephyr", "Plover Inbox", "Gribble secret", "model said Frumious"]

    private func library() async throws -> ReconcileFixture {
        let f = try ReconcileFixture()
        try f.addContext("ctx-a", "Acme Zephyr Corp")
        try f.save([f.finding("Quarterly Zorblax review", people: ["Maximilian Quibble"], place: "Quux Tower")], imageID: f.base.imageID, contextID: "ctx-a")
        _ = await Reconciler(database: f.database, judge: NoMeaningJudge(), now: { now }).reconcile(imageID: f.base.imageID)
        try f.write { db in
            try db.execute(sql: "UPDATE items SET notes = 'Gribble secret agenda'")
            try db.execute(sql: "UPDATE sightings SET window_title = 'Plover Inbox', window_app = 'Mail'")
            try db.execute(sql: """
                INSERT INTO analysis_jobs (id, kind, image_id, state, attempts, failure_reason, created_at, updated_at) VALUES
                ('j1', 'analyse', ?, 'failed', 3, 'the model answered with invalid JSON', datetime('now'), datetime('now')),
                ('j2', 'analyse', ?, 'failed', 3, 'model said Frumious about Zorblax', datetime('now'), datetime('now')),
                ('j3', 'analyse', ?, 'finished', 1, NULL, datetime('now'), datetime('now')),
                ('j4', 'reread', ?, 'waiting', 0, NULL, datetime('now'), datetime('now'))
                """, arguments: StatementArguments(Array(repeating: f.base.imageID, count: 4)))
        }
        try OCRStore(database: f.database).save(imageID: f.base.imageID, lines: [RecognisedLine(n: 1, text: "Wombat invoice 9931", box: PixelBox(x: 1, y: 1, width: 5, height: 5), confidence: 0.9)],
                                                 durationMs: 1, recogniser: "test", at: now)
        return f
    }

    private func report(_ f: ReconcileFixture, log: [LogLine]) throws -> DiagnosticsReport {
        let gatherer = DiagnosticsGatherer(database: f.database, paths: f.base.paths)
        let inputs = try gatherer.inputs(app: AppFacts(version: "1.2.3", build: "45", system: "macOS 26.0"),
                                         permissions: [PermissionState(name: "Screen Recording", state: "allowed"), PermissionState(name: "Calendar", state: "denied")], now: now)
        return DiagnosticsReport.build(inputs, log: log, sensitive: try gatherer.sensitiveStrings())
    }

    private let log = [
        LogLine(category: "reconcile", level: "info", text: "reconciled image=abc findings=2 created=1 merged=0 ms=12", date: Date(timeIntervalSince1970: 1_800_099_000)),
        LogLine(category: "storage", level: "info", text: "reconcile staging=0 orphans=0 missing=0", date: Date(timeIntervalSince1970: 1_800_099_100)),
        LogLine(category: "extraction", level: "error", text: "extract failed for Quarterly Zorblax review", date: Date(timeIntervalSince1970: 1_800_099_200)),     // names an item
        LogLine(category: "extraction", level: "info", text: "found Wombat invoice 9931 on the screen", date: Date(timeIntervalSince1970: 1_800_099_300)),               // OCR-like, not known as a title
        LogLine(category: "extraction", level: "info", text: "one two three four five six seven eight nine ten eleven twelve thirteen words", date: Date(timeIntervalSince1970: 1_800_099_400)),   // too long to be a log line
        LogLine(category: "ollama", level: "info", text: "model server answered", date: Date(timeIntervalSince1970: 1_800_099_500)),
        LogLine(category: "unlisted-category", level: "info", text: "anything", date: Date(timeIntervalSince1970: 1_800_099_600)),
    ]

    @Test func noPlantedStringOfTheLibraryAppearsInTheReportOrItsJSON() async throws {
        let f = try await library(); defer { f.cleanUp() }
        let report = try report(f, log: log)
        for string in planted {
            #expect(!report.text.localizedCaseInsensitiveContains(string), "text contains \(string)")
            #expect(!report.json.localizedCaseInsensitiveContains(string), "json contains \(string)")
        }
        #expect(report.json.hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(report.json.utf8))) != nil)
    }

    @Test func theReportHoldsTheFiguresAndStatesAUserNeedsToSeeWhatIsWrong() async throws {
        let f = try await library(); defer { f.cleanUp() }
        let text = try report(f, log: log).text
        #expect(text.contains("1.2.3") && text.contains("45") && text.contains("macOS 26.0"))
        #expect(text.contains("Screen Recording: allowed") && text.contains("Calendar: denied"))
        #expect(text.contains("analyse") && text.contains("failed") && text.contains("reread"))                      // queue: kinds and states with counts
        #expect(text.contains("the model answered with invalid JSON"))                                               // a failure reason without content stays
        #expect(!text.contains("Frumious") && text.contains("(removed"))                                             // one that names content is replaced
        #expect(text.contains("Items: 1") && text.contains("Captures: 1"))
    }

    @Test func logLinesAreKeptOnlyWhenTheyCanBeShownToHoldNoContent() async throws {
        let f = try await library(); defer { f.cleanUp() }
        let text = try report(f, log: log).text
        #expect(text.contains("reconciled image=abc findings=2 created=1") && text.contains("reconcile staging=0 orphans=0 missing=0") && text.contains("model server answered"))
        #expect(!text.contains("extract failed") && !text.contains("thirteen words") && !text.contains("anything"))
        let kept = text.components(separatedBy: "\n").filter { $0.contains("[reconcile]") || $0.contains("[storage]") || $0.contains("[ollama]") || $0.contains("[extraction]") }
        #expect(kept.count == 3 && !kept.contains { $0.contains("[extraction]") })
    }

    @Test func theSanitiserRulesStandOnTheirOwn() {
        let sensitive: Set<String> = ["zorblax", "abc"]
        #expect(LogSanitiser.keep(LogLine(category: "reconcile", level: "info", text: "created=1", date: now), sensitive: sensitive))
        #expect(!LogSanitiser.keep(LogLine(category: "reconcile", level: "info", text: "ZORBLAX review", date: now), sensitive: sensitive))   // case does not matter
        #expect(LogSanitiser.keep(LogLine(category: "reconcile", level: "info", text: "abc is too short to count", date: now), sensitive: sensitive))   // under four characters is ignored
        #expect(!LogSanitiser.keep(LogLine(category: "search", level: "info", text: "x", date: now), sensitive: []) == false)                      // search is an allowed category
        #expect(!LogSanitiser.keep(LogLine(category: "somewhere", level: "info", text: "x", date: now), sensitive: []))
        #expect(LogSanitiser.sanitiseReason("plain failure", sensitive: sensitive) == "plain failure")
        #expect(LogSanitiser.sanitiseReason("about zorblax", sensitive: sensitive).hasPrefix("(removed"))
    }
}
