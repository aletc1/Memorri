import Foundation
import GRDB

public struct ReconcileCaseScore: Sendable, Equatable, Codable {
    public let name: String
    public let captures: Int
    public let items: Int
    /// Pairs of findings of the same event, and how many ended in one item.
    public let pairs: Int
    public let mergedPairs: Int
    /// The same, for pairs written in different languages.
    public let translatedPairs: Int
    public let translatedMerged: Int
    /// Translated pairs that stayed apart but are linked as a possible duplicate.
    public let translatedFlagged: Int
    /// Items holding findings of more than one event.
    public let wrongMergedItems: Int
    public let comparedPairs: Int
    public let judgedPairs: Int
    public let recreatedDismissed: Int
    public let overwrittenTitles: Int
    public let millis: Double
    public let missedMerges: [String]
    public let wrongMerges: [String]
}

public struct ReconcileOverall: Sendable, Equatable, Codable {
    public let captures: Int
    public let items: Int
    /// Same-event pairs that ended in one item (SC-001). Without the models translated pairs are left out.
    public let mergeRecall: Double
    /// Items holding more than one event, over all items (SC-002).
    public let wrongMergeRate: Double
    /// Compared pairs sent to the judge (SC-006).
    public let judgedShare: Double
    public let msPerCapture: Double
    /// Translated pairs that were merged or left as a possible duplicate; nil when the set has none.
    public let translatedFlagged: Double?
    public let recreatedDismissed: Int
    public let overwrittenTitles: Int
}

/// The result of `memorri-eval reconcile`: how well sightings of the same events end up in one item (contracts/eval-cli.md).
public struct SequenceReport: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public let version: Int
    public let createdAt: Date
    public let models: String
    public let thresholds: ReconcileThresholds
    public let cases: [ReconcileCaseScore]
    public let overall: ReconcileOverall

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SequenceReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SequenceReport.self, from: data)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url)
    }

    public var text: String {
        var lines = ["reconcile (models \(models)): \(overall.captures) captures, \(overall.items) items"]
        lines.append(String(format: "merge recall %.3f  wrong merges %.3f  judged share %.3f  ms/capture %.1f  translated flagged %@",
                            overall.mergeRecall, overall.wrongMergeRate, overall.judgedShare, overall.msPerCapture,
                            overall.translatedFlagged.map { String(format: "%.2f", $0) } ?? "n/a"))
        lines.append("recreated dismissals \(overall.recreatedDismissed)  overwritten user titles \(overall.overwrittenTitles)")
        for c in cases {
            lines.append("case \(c.name): items \(c.items)  merged \(c.mergedPairs)/\(c.pairs)  wrong \(c.wrongMergedItems)  judged \(c.judgedPairs)/\(c.comparedPairs)")
            for pair in c.missedMerges { lines.append("  missed   \(pair)") }
            for item in c.wrongMerges { lines.append("  wrong    \(item)") }
        }
        return lines.joined(separator: "\n")
    }

    public static func compare(_ a: SequenceReport, _ b: SequenceReport) -> String {
        func signed(_ x: Double) -> String { String(format: "%+.2f", x) }
        var lines = ["merge recall \(signed(b.overall.mergeRecall - a.overall.mergeRecall))  wrong merges \(signed(b.overall.wrongMergeRate - a.overall.wrongMergeRate))  judged share \(signed(b.overall.judgedShare - a.overall.judgedShare))  ms/capture \(String(format: "%+.1f", b.overall.msPerCapture - a.overall.msPerCapture))"]
        let before = Dictionary(uniqueKeysWithValues: a.cases.map { ($0.name, $0) })
        var changed = false
        for now in b.cases {
            guard let old = before[now.name], old.mergedPairs != now.mergedPairs || old.wrongMergedItems != now.wrongMergedItems || old.items != now.items else { continue }
            changed = true
            lines.append("changed   \(now.name): merged \(old.mergedPairs)/\(old.pairs) -> \(now.mergedPairs)/\(now.pairs), wrong \(old.wrongMergedItems) -> \(now.wrongMergedItems), items \(old.items) -> \(now.items)")
        }
        if !changed { lines.append("no case changed") }
        return lines.joined(separator: "\n")
    }
}

/// Runs sequence cases through the reconciler on a scratch database, applying what the user does between captures, and scores the result.
public struct ReconcileRunner: Sendable {
    let judge: any MeaningJudging
    let thresholds: ReconcileThresholds
    let modelsOn: Bool

    public init(judge: any MeaningJudging = NoMeaningJudge(), thresholds: ReconcileThresholds = .default, modelsOn: Bool = false) {
        self.judge = judge; self.thresholds = thresholds; self.modelsOn = modelsOn
    }

    public func run(cases: [SequenceCase], only: String? = nil, progress: @Sendable (String) -> Void = { _ in }) async throws -> SequenceReport {
        var scores: [ReconcileCaseScore] = []
        for c in cases where only == nil || c.name == only {
            progress("reconciling \(c.name)")
            scores.append(try await score(c))
        }
        let pairs = scores.reduce(0) { $0 + $1.pairs - (modelsOn ? 0 : $1.translatedPairs) }
        let merged = scores.reduce(0) { $0 + $1.mergedPairs - (modelsOn ? 0 : $1.translatedMerged) }
        let items = scores.reduce(0) { $0 + $1.items }, captures = scores.reduce(0) { $0 + $1.captures }
        let compared = scores.reduce(0) { $0 + $1.comparedPairs }, judged = scores.reduce(0) { $0 + $1.judgedPairs }
        let translated = scores.reduce(0) { $0 + $1.translatedPairs }
        let handled = scores.reduce(0) { $0 + $1.translatedMerged + $1.translatedFlagged }
        let overall = ReconcileOverall(
            captures: captures, items: items, mergeRecall: pairs == 0 ? 1 : Double(merged) / Double(pairs),
            wrongMergeRate: items == 0 ? 0 : Double(scores.reduce(0) { $0 + $1.wrongMergedItems }) / Double(items),
            judgedShare: compared == 0 ? 0 : Double(judged) / Double(compared),
            msPerCapture: captures == 0 ? 0 : scores.reduce(0) { $0 + $1.millis } / Double(captures),
            translatedFlagged: translated == 0 ? nil : Double(handled) / Double(translated),
            recreatedDismissed: scores.reduce(0) { $0 + $1.recreatedDismissed }, overwrittenTitles: scores.reduce(0) { $0 + $1.overwrittenTitles })
        return SequenceReport(version: SequenceReport.currentVersion, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), models: modelsOn ? "on" : "off", thresholds: thresholds,
                               cases: scores, overall: overall)
    }

    // MARK: One case

    private func score(_ c: SequenceCase) async throws -> ReconcileCaseScore {
        let scratch = try Scratch.open(case: c.name)
        defer { scratch.remove() }
        let database = scratch.database, captures = scratch.captures
        let zones = Dictionary(uniqueKeysWithValues: c.contexts.map { ($0.id, $0.timezone ?? c.macTimezone) })
        try await database.pool.write { db in
            for context in c.contexts {
                try db.execute(sql: "INSERT INTO contexts (id, name, timezone, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [context.id, context.name, context.timezone, Date(), Date()])
            }
        }

        var eventOf: [String: String] = [:], langOf: [String: String] = [:], titleOf: [String: String] = [:], findingsOfEvent: [String: [String]] = [:]
        var dismissed: Set<String> = []
        var edits: [(event: String, title: String)] = []
        var compared = 0, judged = 0
        var millis = 0.0
        let clock = ContinuousClock()

        for capture in c.captures {
            let event = CaptureEventRecord(id: "e-\(capture.id)", capturedAt: capture.capturedAt, trigger: "shortcut", status: "complete", failureReason: nil, displayCount: 1)
            let image = CaptureImageRecord(id: "i-\(capture.id)", eventId: event.id, displayId: 1, displayName: "Display", pixelWidth: 100, pixelHeight: 100,
                                           scale: 1, fullPath: "full/\(capture.id)", modelPath: "model/\(capture.id)", modelWidth: 100, modelHeight: 100,
                                           fullBytes: 1, modelBytes: 1, missing: false)
            try captures.insert(event: event, images: [image])
            let zone = capture.context.flatMap { zones[$0] } ?? c.macTimezone
            var findings: [Finding] = []
            for (index, spec) in capture.findings.enumerated() {
                let id = "\(capture.id)#\(index)"
                eventOf[id] = spec.event; titleOf[id] = spec.title; langOf[id] = spec.lang
                findingsOfEvent[spec.event, default: []].append(id)
                findings.append(Self.finding(spec, id: id, timezone: zone))
            }
            try Self.save(findings, imageID: image.id, context: capture.context, database: database, at: capture.capturedAt)
            let at = capture.capturedAt
            let reconciler = Reconciler(database: database, judge: judge, thresholds: thresholds, now: { at })
            let started = clock.now
            let summary = await reconciler.reconcile(imageID: image.id)
            let elapsed = started.duration(to: clock.now).components
            millis += Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            if let error = summary.error { throw SequenceCaseError.invalid(case: c.name, reason: "reconcile failed on \(capture.id): \(error)") }
            compared += summary.compared; judged += summary.judged

            let operations = ItemOperations(database: database, now: { at })
            for action in c.actions where action.after == capture.id {
                guard let itemID = try Self.latestItem(of: findingsOfEvent[action.event] ?? [], in: database) else { continue }
                switch action.action {
                case .dismiss: if (try? operations.dismiss(itemID)) != nil { dismissed.insert(action.event) }
                case .restore: if (try? operations.restore(itemID)) != nil { dismissed.remove(action.event) }
                case .editTitle:
                    if let title = action.title, (try? operations.edit(itemID, field: .title, value: .string(title))) != nil { edits.append((action.event, title)) }
                case .split:
                    if let sighting = try Self.latestSighting(of: findingsOfEvent[action.event] ?? [], in: database) { _ = try? operations.split(itemID, sightings: [sighting]) }
                }
            }
        }
        return try Self.measure(c, database: database, eventOf: eventOf, langOf: langOf, titleOf: titleOf, findingsOfEvent: findingsOfEvent,
                                dismissed: dismissed, edits: edits, compared: compared, judged: judged, millis: millis)
    }

    // MARK: Reanalysis (run --reconcile)

    /// Reconciles what the analysis found in every case into one database, the way the app would (each case is a picture), then stores a
    /// second analysis of the same pictures and reconciles again (SC-003, SC-007): a second reading of the same pictures should create no item.
    public func reanalysis(first: [String: [FoundFinding]], second: [String: [FoundFinding]], expectedEvents: Int? = nil,
                           progress: @Sendable (String) -> Void = { _ in }) async throws -> ReanalysisReport {
        let scratch = try Scratch.open(case: "reanalysis")
        defer { scratch.remove() }
        let names = first.keys.sorted()
        let base = Date(timeIntervalSince1970: 1_791_900_000)
        var images: [String: String] = [:]
        for (index, name) in names.enumerated() {
            let at = base.addingTimeInterval(Double(index) * 60)
            let event = CaptureEventRecord(id: "e\(index)", capturedAt: at, trigger: "shortcut", status: "complete", failureReason: nil, displayCount: 1)
            let image = CaptureImageRecord(id: "i\(index)", eventId: event.id, displayId: 1, displayName: "Display", pixelWidth: 100, pixelHeight: 100, scale: 1,
                                           fullPath: "full/\(index)", modelPath: "model/\(index)", modelWidth: 100, modelHeight: 100, fullBytes: 1, modelBytes: 1, missing: false)
            try scratch.captures.insert(event: event, images: [image])
            images[name] = image.id
        }
        func pass(_ found: [String: [FoundFinding]], tag: String) async throws -> Set<String> {
            for (index, name) in names.enumerated() {
                progress("reconciling \(tag) \(name)")
                let at = base.addingTimeInterval(Double(index) * 60 + (tag == "a" ? 0 : 3600))
                let findings = (found[name] ?? []).enumerated().map { Self.finding(from: $1, id: "\(tag)-\(name)#\($0)") }
                try Self.save(findings, imageID: images[name]!, context: nil, database: scratch.database, at: at)
                let summary = await Reconciler(database: scratch.database, judge: judge, thresholds: thresholds, now: { at }).reconcile(imageID: images[name]!)
                if let error = summary.error { throw SequenceCaseError.invalid(case: name, reason: "reconcile failed: \(error)") }
            }
            return try await scratch.database.pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM items WHERE status != 'merged'")) }
        }
        let one = try await pass(first, tag: "a")
        let two = try await pass(second, tag: "b")
        return ReanalysisReport(captures: names.count, findingsFirst: first.values.reduce(0) { $0 + $1.count },
                                findingsSecond: second.values.reduce(0) { $0 + $1.count }, itemsFirst: one.count, itemsSecond: two.count,
                                createdBySecond: two.subtracting(one).count, expectedEvents: expectedEvents)
    }

    static func finding(from found: FoundFinding, id: String) -> Finding {
        var provenance: [String: FieldProvenance] = [:]
        for (field, present) in [("start", found.start != nil), ("end", found.end != nil), ("due", found.due != nil)] where present {
            provenance[field] = found.inferred.contains(field) ? FieldProvenance(origin: .inferred, rule: "default-duration") : FieldProvenance(origin: .read, rule: "explicit-date")
        }
        return Finding(id: id, kind: FindingKind(rawValue: found.kind) ?? .appointment, title: found.title, allDay: found.allDay, start: found.start, end: found.end,
                       due: found.due, timezone: "UTC", people: found.people, place: found.place, citedLines: [1], confidence: found.confidence, provenance: provenance)
    }

    // MARK: Building the findings

    static func finding(_ spec: SequenceCase.FindingSpec, id: String, timezone: String) -> Finding {
        var provenance: [String: FieldProvenance] = [:]
        for (field, present) in [("start", spec.start != nil), ("end", spec.end != nil), ("due", spec.due != nil)] where present {
            provenance[field] = spec.inferred.contains(field) ? FieldProvenance(origin: .inferred, rule: "default-duration") : FieldProvenance(origin: .read, rule: "explicit-date")
        }
        return Finding(id: id, kind: spec.kind, title: spec.title, allDay: spec.allDay, start: spec.start, end: spec.end, due: spec.due, timezone: timezone,
                       people: spec.people, place: spec.place, citedLines: [1], confidence: spec.confidence, provenance: provenance)
    }

    static func save(_ findings: [Finding], imageID: String, context: String?, database: StorageDatabase, at date: Date) throws {
        let classification = ClassificationResult(kind: .calendarWeek, confidence: 0.9, application: "Calendar", platformLook: "macos", isRemote: false,
                                                  remoteClient: "", theme: "light", calendarName: "")
        let decision = context == nil ? ContextDecision.unassigned : ContextDecision(contextID: context, source: .auto, score: 1)
        let result = AnalysisResult(lines: [], classification: classification, findings: findings, decision: decision, timezone: TimeZone(identifier: "UTC")!,
                                    model: "synthetic", pictureLongEdge: 2048)
        try AnalysisResultStore(database: database).save(result, imageID: imageID, runID: nil, at: date)
    }

    static func latestSighting(of findingIDs: [String], in database: StorageDatabase) throws -> String? {
        guard !findingIDs.isEmpty else { return nil }
        return try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM sightings WHERE finding_id IN (\(findingIDs.map { _ in "?" }.joined(separator: ", "))) ORDER BY captured_at DESC, rowid DESC LIMIT 1",
                                arguments: StatementArguments(findingIDs))
        }
    }

    static func latestItem(of findingIDs: [String], in database: StorageDatabase) throws -> String? {
        guard !findingIDs.isEmpty else { return nil }
        return try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT item_id FROM sightings WHERE finding_id IN (\(findingIDs.map { _ in "?" }.joined(separator: ", "))) ORDER BY captured_at DESC, rowid DESC LIMIT 1",
                                arguments: StatementArguments(findingIDs))
        }
    }

    // MARK: Scoring

    private static func measure(_ c: SequenceCase, database: StorageDatabase, eventOf: [String: String], langOf: [String: String], titleOf: [String: String],
                                findingsOfEvent: [String: [String]], dismissed: Set<String>, edits: [(event: String, title: String)],
                                compared: Int, judged: Int, millis: Double) throws -> ReconcileCaseScore {
        let (itemOf, flagged, itemTitles, activeItems): ([String: String], Set<[String]>, [String: String], Set<String>) = try database.pool.read { db in
            var itemOf: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT finding_id, item_id FROM sightings") { itemOf[row["finding_id"]] = row["item_id"] }
            var flagged: Set<[String]> = []
            for row in try Row.fetchAll(db, sql: "SELECT item_a, item_b FROM possible_duplicates") { flagged.insert([row["item_a"], row["item_b"]]) }
            var titles: [String: String] = [:], active: Set<String> = []
            for row in try Row.fetchAll(db, sql: "SELECT id, title, status FROM items") {
                titles[row["id"]] = row["title"]
                if (row["status"] as String) == "active" { active.insert(row["id"]) }
            }
            return (itemOf, flagged, titles, active)
        }

        var pairs = 0, merged = 0, translated = 0, translatedMerged = 0, translatedFlagged = 0
        var missed: [String] = []
        for ids in findingsOfEvent.values {
            let ordered = ids.sorted()
            for i in ordered.indices {
                for j in ordered.indices where j > i {
                    guard let a = itemOf[ordered[i]], let b = itemOf[ordered[j]] else { continue }
                    let isTranslated = langOf[ordered[i]] != nil && langOf[ordered[j]] != nil && langOf[ordered[i]] != langOf[ordered[j]]
                    pairs += 1; if isTranslated { translated += 1 }
                    if a == b {
                        merged += 1; if isTranslated { translatedMerged += 1 }
                    } else {
                        if isTranslated, flagged.contains([a, b].sorted()) { translatedFlagged += 1 }
                        missed.append("\(titleOf[ordered[i]] ?? "?") | \(titleOf[ordered[j]] ?? "?")")
                    }
                }
            }
        }

        var eventsOfItem: [String: Set<String>] = [:]
        for (finding, item) in itemOf { if let event = eventOf[finding] { eventsOfItem[item, default: []].insert(event) } }
        let wrong = eventsOfItem.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            .map { "\(itemTitles[$0.key] ?? "?"): events \($0.value.sorted().joined(separator: ", "))" }

        var recreated = 0
        for event in dismissed {
            let items = Set((findingsOfEvent[event] ?? []).compactMap { itemOf[$0] })
            recreated += items.filter(activeItems.contains).count
        }
        var overwritten = 0
        for edit in edits {
            let items = Set((findingsOfEvent[edit.event] ?? []).compactMap { itemOf[$0] })
            if !items.contains(where: { itemTitles[$0] == edit.title }) { overwritten += 1 }
        }
        return ReconcileCaseScore(name: c.name, captures: c.captures.count, items: eventsOfItem.count, pairs: pairs, mergedPairs: merged,
                                  translatedPairs: translated, translatedMerged: translatedMerged, translatedFlagged: translatedFlagged,
                                  wrongMergedItems: wrong.count, comparedPairs: compared, judgedPairs: judged, recreatedDismissed: recreated,
                                  overwrittenTitles: overwritten, millis: millis, missedMerges: missed.sorted(), wrongMerges: wrong)
    }
}


/// A scratch database in a temporary folder, removed afterwards.
struct Scratch {
    let root: URL
    let database: StorageDatabase
    let captures: CaptureStore

    static func open(case name: String) throws -> Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memorri-eval-\(UUID().uuidString)")
        let paths = AppPaths(root: root.appendingPathComponent("Memorri"))
        try paths.prepare()
        guard case .opened(let database) = try StorageDatabase.open(paths: paths) else { throw SequenceCaseError.invalid(case: name, reason: "scratch database") }
        return Scratch(root: root, database: database, captures: CaptureStore(database: database))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// What `run --reconcile` adds to the analysis report (SC-003 and SC-007).
public struct ReanalysisReport: Sendable, Equatable, Codable {
    public let captures: Int
    public let findingsFirst: Int
    public let findingsSecond: Int
    public let itemsFirst: Int
    public let itemsSecond: Int
    /// Items that exist after the second analysis and did not after the first.
    public let createdBySecond: Int
    /// Findings the golden cases expect, when known: the analysis may find more (its own precision), reconciliation never adds items.
    public let expectedEvents: Int?

    public var text: String {
        var line = "reconcile: \(captures) captures, \(findingsFirst) findings became \(itemsFirst) items"
        if let expectedEvents { line += " (the cases expect \(expectedEvents) events)" }
        return line + "; after the second analysis \(itemsSecond) items, \(createdBySecond) of them new"
    }
}
