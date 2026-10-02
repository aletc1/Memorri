import Foundation
import GRDB

public struct TrialSkip: Sendable, Equatable {
    public let id: String
    public let reason: String
}

public struct TrialApplyResult: Sendable, Equatable {
    /// The `apply_trial` operation (undoable); nil when nothing was applied.
    public let operationID: String?
    public let applied: [String]
    public let skipped: [TrialSkip]
}

/// Applies chosen differences of a trial as one operation (spec 008, US3, ADR 0025). Each applied difference adds the proposal's sighting to
/// its item (or to a new item) in place of the capture's earlier sighting of that item, then the item is recomputed with the usual rules, so
/// locks and the Inbox work as for a new capture. What was removed is stored with the operation, so Undo puts it back exactly.
public struct TrialApplier: Sendable {
    let database: StorageDatabase
    let reconciler: Reconciler
    let store: TrialStore
    let evidence: (any ImageEvidenceWriting)?
    let now: @Sendable () -> Date

    public init(database: StorageDatabase, reconciler: Reconciler, store: TrialStore, evidence: (any ImageEvidenceWriting)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.reconciler = reconciler; self.store = store; self.evidence = evidence; self.now = now
    }

    public static func reasonText(_ difference: TrialDifference) -> String {
        if difference.state == .applied { return "Already applied" }
        switch difference.protection {
        case .locked(let fields)?: return "You set \(fields.map(\.rawValue).joined(separator: ", "))"
        case .approved?: return "You approved this item"
        case .dismissed?: return "You dismissed this item"
        case nil: break
        }
        switch difference.kind {
        case .unchanged: return "Nothing to change"
        case .notFound: return "Not found in this trial; nothing is removed"
        default: return "No longer applies"
        }
    }

    /// Applies `differenceIDs` of the trial. Every difference is checked again against the items as they are now; the ones that no longer
    /// hold, or are protected, are skipped with a reason.
    public func apply(trialID: String, differenceIDs: [String]) async throws -> TrialApplyResult {
        guard let trial = try store.trial(id: trialID) else { throw TrialError.notFound }
        let wanted = Set(differenceIDs)

        // Re-check: the plan and the classification are made again from the library as it is.
        struct ImageWork: Sendable { let imageID: String; let proposals: [Finding]; let plan: ReconcilePlan; let selected: Set<String> }
        var work: [ImageWork] = []
        var skipped: [TrialSkip] = []
        var known: Set<String> = []
        for imageID in try store.readImageIDs(trialID: trialID) {
            let proposals = try store.findings(trialID: trialID, imageID: imageID)
            let plan = try await reconciler.plan(imageID: imageID, findings: proposals)
            let differences = try await database.pool.read { try TrialComparison.classify($0, imageID: imageID, proposals: proposals, plan: plan) }
            var selected: Set<String> = []
            for d in differences where wanted.contains(d.id) {
                known.insert(d.id)
                if d.applicable { selected.insert(d.id) } else { skipped.append(TrialSkip(id: d.id, reason: Self.reasonText(d))) }
            }
            if !selected.isEmpty { work.append(ImageWork(imageID: imageID, proposals: proposals, plan: plan, selected: selected)) }
        }
        for id in differenceIDs where !known.contains(id) { skipped.append(TrialSkip(id: id, reason: "No longer applies")) }
        guard !work.isEmpty else { return TrialApplyResult(operationID: nil, applied: [], skipped: skipped) }

        let date = now()
        let jobs = work
        let outcome: (op: String?, applied: [String], skipped: [TrialSkip], images: [String]) = try await database.pool.write { db in
            var applied: [String] = []
            var lost: [TrialSkip] = []
            var created: [String] = []
            var newSightings: [String] = []
            var removed: [JSONValue] = []
            var touched: [String] = []
            var before: [String: ItemState] = [:]
            func touch(_ id: String) { if !touched.contains(id) { touched.append(id) } }

            for item in jobs {
                let byID = Dictionary(item.proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let context = try String?.fetchOne(db, sql: "SELECT context_id FROM image_context WHERE image_id = ?", arguments: [item.imageID]) ?? nil
                let capturedAt = try Date.fetchOne(db, sql: "SELECT e.captured_at FROM capture_images i JOIN capture_events e ON e.id = i.event_id WHERE i.id = ?",
                                                   arguments: [item.imageID]) ?? date
                // A step that joins another's item needs that step's item, so it is made too.
                var needed = Set(item.plan.steps.indices.filter { item.selected.contains(item.plan.steps[$0].findingID) })
                var grew = true
                while grew {
                    grew = false
                    for index in needed.sorted() { if case .sameAsStep(let n) = item.plan.steps[index].target, needed.insert(n).inserted { grew = true } }
                }
                var resolved: [Int: String] = [:]
                var cleared: Set<String> = []
                for (index, step) in item.plan.steps.enumerated() where needed.contains(index) {
                    guard let finding = byID[step.findingID] else { continue }
                    var itemID: String?
                    var possibleOf: String?
                    switch step.target {
                    case .existing(let id): itemID = try Reconciler.live(db, id)
                    case .sameAsStep(let n): itemID = resolved[n]
                    case .newItem: break
                    case .newWithPossibleDuplicate(let other): possibleOf = try Reconciler.live(db, other)
                    }
                    var joined = itemID != nil
                    if case .existing = step.target, itemID == nil { lost.append(TrialSkip(id: finding.id, reason: "The item no longer exists")); continue }
                    if case .sameAsStep = step.target, itemID == nil { lost.append(TrialSkip(id: finding.id, reason: "No longer applies")); continue }
                    if itemID == nil {
                        let id = UUID().uuidString
                        try ItemStore.insert(db, Item(id: id, kind: finding.kind, contextID: context, title: finding.title, timezone: finding.timezone,
                                                      confidence: finding.confidence, firstSeen: capturedAt, lastSeen: capturedAt), at: date)
                        itemID = id; created.append(id); joined = false
                        if let possibleOf {
                            let pair = [id, possibleOf].sorted()
                            try db.execute(sql: "INSERT OR IGNORE INTO possible_duplicates (item_a, item_b, scores_json, created_at) VALUES (?, ?, '{}', ?)",
                                           arguments: [pair[0], pair[1], date])
                            if before[possibleOf] == nil, let state = try OperationLog.state(db, itemID: possibleOf) { before[possibleOf] = state }
                            touch(possibleOf)
                        }
                    }
                    guard let target = itemID else { continue }
                    if joined, cleared.insert(target).inserted {
                        if before[target] == nil, let state = try OperationLog.state(db, itemID: target) { before[target] = state }
                        // The capture's earlier sightings of this item give way to the proposal; they are stored for Undo.
                        for sighting in try Row.fetchAll(db, sql: "SELECT * FROM sightings WHERE image_id = ? AND item_id = ?", arguments: [item.imageID, target]) {
                            let sightingID: String = sighting["id"]
                            let observations = try Row.fetchAll(db, sql: "SELECT * FROM observations WHERE sighting_id = ?", arguments: [sightingID])
                            removed.append(.object(["item": .string(target), "sighting": Self.json(sighting), "observations": .array(observations.map(Self.json))]))
                        }
                        try db.execute(sql: "DELETE FROM sightings WHERE image_id = ? AND item_id = ?", arguments: [item.imageID, target])
                    }
                    resolved[index] = target
                    let window = try store.window(db, findingID: finding.id)
                    newSightings.append(try Reconciler.attach(db, finding: finding, itemID: target, imageID: item.imageID, capturedAt: capturedAt,
                                                              step: step, at: date, window: window))
                    touch(target)
                    if item.selected.contains(finding.id) { applied.append(finding.id) }
                }
            }
            guard !newSightings.isEmpty else { return (nil, [], lost, []) }
            for id in touched { try ItemStore.recompute(db, itemID: id, at: date) }
            let detail: [String: JSONValue] = [
                "trial": .string(trialID), "model": .string(trial.model), "promptVersion": .string(trial.promptVersion),
                // What the audit trail keeps of the trial itself, so it outlives deleting the trial.
                "trialStarted": .string(ISO8601DateFormatter().string(from: trial.createdAt)), "captures": .int(trial.counts.read),
                "differences": .array(applied.map(JSONValue.string)), "created": .array(created.map(JSONValue.string)),
                "sightings": .array(newSightings.map(JSONValue.string)), "removed": .array(removed),
                "images": .array(jobs.map { .string($0.imageID) }),
            ]
            let id = try OperationLog.record(db, kind: .applyTrial, byUser: true, items: touched, before: before, detail: detail, at: date)
            return (id, applied, lost, jobs.map(\.imageID))
        }
        for imageID in outcome.images { _ = await evidence?.write(imageID: imageID) }
        return TrialApplyResult(operationID: outcome.op, applied: outcome.applied, skipped: skipped + outcome.skipped)
    }

    /// A row as JSON, so an undo can put it back column for column.
    static func json(_ row: Row) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (column, value) in row {
            switch value.storage {
            case .null: object[column] = .null
            case .int64(let n): object[column] = .int(Int(n))
            case .double(let x): object[column] = .double(x)
            case .string(let text): object[column] = .string(text)
            case .blob: break
            }
        }
        return .object(object)
    }
}
