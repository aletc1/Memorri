import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct AnalysisResultStoreTests {
    private let at = Date(timeIntervalSinceReferenceDate: 5000)

    private func classification(_ kind: ScreenKind = .calendarWeek) -> ClassificationResult {
        ClassificationResult(kind: kind, confidence: 0.9, application: "Outlook", platformLook: "windows", isRemote: false,
                             remoteClient: "", theme: "light", calendarName: "")
    }

    private func finding(id: String = UUID().uuidString, title: String = "Team sync") -> Finding {
        let tags = [CaptureTag(key: "application", value: "Outlook", confidence: 0.9, source: "visual")]
        return Finding(id: id, kind: .appointment, title: title, allDay: false,
                       start: Date(timeIntervalSinceReferenceDate: 1000), end: Date(timeIntervalSinceReferenceDate: 4600),
                       timezone: "Europe/Madrid", people: ["Ana", "Ben"], place: "Room 4", notes: "bring slides",
                       citedLines: [2, 3], confidence: 0.5,
                       provenance: ["start": FieldProvenance(origin: .read, rule: "explicit-date"),
                                    "end": FieldProvenance(origin: .inferred, rule: "block-height", reason: "block-height")],
                       unresolved: ["due": "Friday"], tags: tags)
    }

    private func result(findings: [Finding], kind: ScreenKind = .calendarWeek, decision: ContextDecision = .unassigned,
                        discards: [CitationCheck.Discard] = []) -> AnalysisResult {
        AnalysisResult(lines: [], classification: classification(kind), tags: [CaptureTag(key: "theme", value: "light", confidence: 0.8, source: "visual"),
                                                                                 CaptureTag(key: "display_size", value: "1200x600", confidence: 1, source: "code")],
                       findings: findings, discards: discards, decision: decision, timezone: TimeZone(identifier: "Europe/Madrid")!,
                       timezoneSource: "mac", lineCapApplied: true, model: "qwen3.8:27b-mlx", pictureLongEdge: 2048, steps: [])
    }

    private func count(_ fixture: PipelineFixture, _ table: String) throws -> Int {
        try fixture.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    @Test func saveWritesAnalysisFindingsTagsAndContextTogether() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try fixture.database.pool.write {
            try $0.execute(sql: "INSERT INTO contexts (id, name, timezone, created_at, updated_at) VALUES ('c1', 'Customer A', 'America/New_York', ?, ?)",
                           arguments: [at, at])
        }
        let decision = ContextDecision(contextID: "c1", source: .auto, score: 5.5,
                                       matched: [MatchedHint(hintKind: "window_title", value: "Customer A", points: 3)],
                                       runnerUp: RunnerUp(contextId: "c2", score: 1))
        let store = AnalysisResultStore(database: fixture.database)
        try store.save(result(findings: [finding(), finding(title: "Other")], decision: decision,
                              discards: [CitationCheck.Discard(title: "Bad", reason: "cites no line", citedLines: [])]),
                       imageID: fixture.imageID, runID: nil, at: at)

        let stored = try #require(try store.analysis(imageID: fixture.imageID))
        #expect(stored.kind == .calendarWeek && stored.kindConfidence == 0.9 && stored.model == "qwen3.8:27b-mlx")
        #expect(stored.classifyVersion == "classify-v2" && stored.promptVersion == "extract-calendar_week-v4" && stored.schemaVersion == "schema-calendar_week-v1")
        #expect(stored.pictureLongEdge == 2048 && stored.timezone == "Europe/Madrid" && stored.timezoneSource == "mac")
        #expect(stored.findingCount == 2 && stored.lineCapApplied && stored.analysedAt == at)
        #expect(stored.discarded == [CitationCheck.Discard(title: "Bad", reason: "cites no line", citedLines: [])])
        #expect(try store.tags(imageID: fixture.imageID).map(\.key).sorted() == ["display_size", "theme"])
        let row = try fixture.database.pool.read { try Row.fetchOne($0, sql: "SELECT * FROM image_context WHERE image_id = ?", arguments: [fixture.imageID]) }
        #expect(row?["context_id"] as String? == "c1" && row?["source"] as String? == "auto" && row?["score"] as Double? == 5.5)
        #expect((row?["matched_json"] as String?)?.contains("Customer A") == true)
        #expect((row?["runner_up_json"] as String?)?.contains("c2") == true)
    }

    @Test func aFailureHalfWayLeavesNothing() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        let same = finding(id: "same")
        #expect(throws: (any Error).self) { try store.save(result(findings: [same, same]), imageID: fixture.imageID, runID: nil, at: at) }
        for table in ["image_analysis", "findings", "capture_tags", "image_context"] { #expect(try count(fixture, table) == 0, Comment(rawValue: table)) }
        #expect(try store.analysis(imageID: fixture.imageID) == nil)
    }

    @Test func savingAgainReplacesEverythingAndKeepsTheRuns() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let jobs = AnalysisStore(database: fixture.database)
        try jobs.enqueue(AnalysisJobRecord(id: "j", imageId: fixture.imageID, createdAt: at))
        try jobs.record(run: ModelRunRecord(id: "r1", jobId: "j", imageId: fixture.imageID, attempt: 1, model: "m", think: "off", temperature: 0,
                                            imageLongEdge: 1024, promptVersion: "classify-v1", schemaVersion: "s", startedAt: at, durationMs: 1,
                                            outcome: .success, failureReason: nil, requestJson: "{}", rawAnswer: "{}", step: "classify"))
        let store = AnalysisResultStore(database: fixture.database)
        try store.save(result(findings: [finding(), finding(title: "B")]), imageID: fixture.imageID, runID: "r1", at: at)
        try store.save(result(findings: [finding(title: "Only")], kind: .email), imageID: fixture.imageID, runID: "r1", at: at.addingTimeInterval(60))
        #expect(try store.findings(imageID: fixture.imageID).map(\.title) == ["Only"])
        #expect(try store.analysis(imageID: fixture.imageID)?.kind == .email)
        #expect(try count(fixture, "image_analysis") == 1 && count(fixture, "capture_tags") == 2 && count(fixture, "model_runs") == 1)
    }

    @Test func aUserChoiceOfContextSurvivesASave() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        try fixture.database.pool.write { db in
            for id in ["mine", "auto"] {
                try db.execute(sql: "INSERT INTO contexts (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", arguments: [id, id, at, at])
            }
            try db.execute(sql: "INSERT INTO image_context (image_id, context_id, source, score, decided_at) VALUES (?, 'mine', 'user', 0, ?)",
                           arguments: [fixture.imageID, at])
        }
        let store = AnalysisResultStore(database: fixture.database)
        try store.save(result(findings: [], decision: ContextDecision(contextID: "auto", source: .auto, score: 4)), imageID: fixture.imageID, runID: nil, at: at)
        let row = try fixture.database.pool.read { try Row.fetchOne($0, sql: "SELECT context_id, source FROM image_context WHERE image_id = ?", arguments: [fixture.imageID]) }
        #expect(row?["context_id"] as String? == "mine" && row?["source"] as String? == "user")
    }

    @Test func findingsRoundTripTheirDetails() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        let original = finding(id: "f1")
        try store.save(result(findings: [original]), imageID: fixture.imageID, runID: nil, at: at)
        let back = try #require(try store.findings(imageID: fixture.imageID).first)
        #expect(back == original)
        #expect(back.provenance["end"]?.reason == "block-height" && back.unresolved == ["due": "Friday"] && back.tags.count == 1)
        #expect(back.citedLines == [2, 3] && back.people == ["Ana", "Ben"] && back.place == "Room 4" && back.notes == "bring slides")
    }

    @Test func anAllDayFindingWithoutDatesRoundTrips() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        let bare = Finding(id: "f2", kind: .deadline, title: "Submit", allDay: true, timezone: "UTC", citedLines: [1], confidence: 0.8)
        try store.save(result(findings: [bare]), imageID: fixture.imageID, runID: nil, at: at)
        #expect(try store.findings(imageID: fixture.imageID) == [bare])
    }

    @Test func unanalysedPicturesExcludeAnalysedOnesAndOnesWithAWaitingOrRunningJob() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        #expect(try store.unanalysedImageIDs() == [fixture.imageID])

        let jobs = AnalysisStore(database: fixture.database)
        try jobs.enqueue(AnalysisJobRecord(id: "j1", kind: "analyse", imageId: fixture.imageID, createdAt: at))
        #expect(try store.unanalysedImageIDs().isEmpty)
        try jobs.markRunning(id: "j1", now: at)
        #expect(try store.unanalysedImageIDs().isEmpty)
        try jobs.markFailed(id: "j1", failedAttempts: 3, reason: "x", now: at)
        #expect(try store.unanalysedImageIDs() == [fixture.imageID])
        try jobs.markFinished(id: "j1", now: at)
        #expect(try store.unanalysedImageIDs() == [fixture.imageID])

        try store.save(result(findings: []), imageID: fixture.imageID, runID: nil, at: at)
        #expect(try store.unanalysedImageIDs().isEmpty)
    }

    @Test func unanalysedPicturesComeOldestFirstAndSkipMissingFiles() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        func add(_ id: String, at seconds: TimeInterval, missing: Bool = false) throws {
            let event = makeEventRecord(id: "e-\(id)", at: Date(timeIntervalSinceReferenceDate: seconds))
            var image = makeImageRecord(eventID: event.id, id: id)
            image.missing = missing
            try fixture.captures.insert(event: event, images: [image])
        }
        try add("newer", at: 9_000_000_000)
        try add("older", at: 10)
        try add("gone", at: 5, missing: true)
        let ids = try AnalysisResultStore(database: fixture.database).unanalysedImageIDs()
        #expect(ids.filter { $0 != fixture.imageID } == ["older", "newer"])
        #expect(!ids.contains("gone"))
    }

    @Test func deletingTheCaptureRemovesEverythingThatBelongsToIt() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        try store.save(result(findings: [finding()], decision: ContextDecision(contextID: nil, source: .none, score: 0)), imageID: fixture.imageID, runID: nil, at: at)
        try fixture.captures.deleteEvents(ids: [fixture.event.id])
        for table in ["image_analysis", "findings", "capture_tags", "image_context"] { #expect(try count(fixture, table) == 0, Comment(rawValue: table)) }
    }

    @Test func reanalysisReplacesTheTagsAndEachFindingKeepsACopyOfThem() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let store = AnalysisResultStore(database: fixture.database)
        try store.save(result(findings: [finding()]), imageID: fixture.imageID, runID: nil, at: at)
        let second = AnalysisResult(lines: [], classification: classification(), tags: [CaptureTag(key: "clock_style", value: "24h", confidence: 1, source: "code")],
                                    findings: [finding()], timezone: .current, model: "m")
        try store.save(second, imageID: fixture.imageID, runID: nil, at: at.addingTimeInterval(60))
        #expect(try store.tags(imageID: fixture.imageID).map(\.key) == ["clock_style"])
        #expect(try count(fixture, "capture_tags") == 1)
    }
}
