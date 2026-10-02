import Foundation
import GRDB

/// Why a difference cannot be applied: the user's own choices win (constitution IV, spec 008 FR-006).
public enum ProtectionReason: Sendable, Equatable {
    case locked([ItemField])
    case approved
    case dismissed
}

public struct FieldChange: Sendable, Equatable {
    public let field: ItemField
    public let current: String
    public let proposed: String
}

/// One thing a trial would change, found by comparing its proposal for a capture with the items as they are now.
public struct TrialDifference: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case new, changed, unchanged, notFound }
    public enum State: String, Sendable { case open, applied }

    /// The proposal finding's id; `notFound:<image>:<item>` for an item the trial did not find.
    public let id: String
    public let kind: Kind
    public let imageID: String
    public let itemID: String?
    public let findingID: String?
    public let title: String
    public let changes: [FieldChange]
    public let protection: ProtectionReason?
    public let state: State
    public let confidence: Double?
    /// The proposal would be sent to the Inbox (low confidence or a guessed time).
    public let needsReview: Bool

    /// Something Apply can do: a new item or a change, not protected, not applied yet.
    public var applicable: Bool { (kind == .new || kind == .changed) && protection == nil && state == .open }
}

public struct TrialTotals: Sendable, Equatable {
    public var new = 0, changed = 0, unchanged = 0, notFound = 0, protected = 0, review = 0, applied = 0
}

public struct TrialReport: Sendable, Equatable {
    public let trialID: String
    public let differences: [TrialDifference]
    public var totals: TrialTotals {
        var totals = TrialTotals()
        for d in differences {
            if d.state == .applied { totals.applied += 1; continue }
            switch d.kind {
            case .new: totals.new += 1
            case .changed: totals.changed += 1
            case .unchanged: totals.unchanged += 1
            case .notFound: totals.notFound += 1
            }
            if d.protection != nil { totals.protected += 1 }
            if d.needsReview, d.kind == .new || d.kind == .changed { totals.review += 1 }
        }
        return totals
    }
}

/// Compares what a trial read with the items as they are, without writing (spec 008, US2). The matching is the reconciler's own plan run over
/// the proposals, so a proposal joins the item a new capture of it would join.
public struct TrialComparison: Sendable {
    let database: StorageDatabase
    let reconciler: Reconciler
    let store: TrialStore

    public init(database: StorageDatabase, reconciler: Reconciler, store: TrialStore) {
        self.database = database; self.reconciler = reconciler; self.store = store
    }

    /// How many captures are compared at once (reads run side by side; the plan is made without writing).
    private static let width = 8

    public func report(trialID: String) async throws -> TrialReport {
        let images = try store.readImageIDs(trialID: trialID)
        var results = [[TrialDifference]](repeating: [], count: images.count)
        try await withThrowingTaskGroup(of: (Int, [TrialDifference]).self) { group in
            var next = 0
            func add(_ group: inout ThrowingTaskGroup<(Int, [TrialDifference]), Error>) {
                guard next < images.count else { return }
                let index = next, imageID = images[next]
                next += 1
                group.addTask { (index, try await self.differences(trialID: trialID, imageID: imageID)) }
            }
            for _ in 0..<Self.width { add(&group) }
            while let (index, found) = try await group.next() {
                results[index] = found
                add(&group)
            }
        }
        return TrialReport(trialID: trialID, differences: results.flatMap { $0 })
    }

    func differences(trialID: String, imageID: String) async throws -> [TrialDifference] {
        let proposals = try store.findings(trialID: trialID, imageID: imageID)
        let plan = try await reconciler.plan(imageID: imageID, findings: proposals)
        return try await database.pool.read { db in try Self.classify(db, imageID: imageID, proposals: proposals, plan: plan) }
    }

    static func classify(_ db: Database, imageID: String, proposals: [Finding], plan: ReconcilePlan) throws -> [TrialDifference] {
        let byID = Dictionary(proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sightings = try Row.fetchAll(db, sql: "SELECT item_id, finding_id FROM sightings WHERE image_id = ?", arguments: [imageID])
        let applied = Set(sightings.compactMap { $0["finding_id"] as String? })
        var resolved: [Int: String] = [:]
        var found: Set<String> = []
        var out: [TrialDifference] = []

        for (index, step) in plan.steps.enumerated() {
            guard let finding = byID[step.findingID] else { continue }
            var itemID: String?
            switch step.target {
            case .existing(let id): itemID = try Reconciler.live(db, id)
            case .sameAsStep(let n): itemID = resolved[n]
            case .newItem, .newWithPossibleDuplicate: break
            }
            if let itemID { resolved[index] = itemID; found.insert(itemID) }
            let state: TrialDifference.State = applied.contains(finding.id) ? .applied : .open
            let review = finding.confidence < ReviewRules.level || finding.provenance.values.contains { $0.origin == .inferred }
            if let itemID, let item = try ItemStore.item(db, id: itemID) {
                let changes = Self.changes(from: item, to: finding)
                var protection: ProtectionReason?
                if !changes.isEmpty {
                    let locked = Set(try String.fetchAll(db, sql: "SELECT field FROM field_locks WHERE item_id = ?", arguments: [itemID]).compactMap(ItemField.init(rawValue:)))
                    let touched = changes.map(\.field).filter(locked.contains)
                    if item.status == .dismissed { protection = .dismissed }
                    else if !touched.isEmpty { protection = .locked(touched) }
                    else if item.approvedAt != nil { protection = .approved }
                }
                out.append(TrialDifference(id: finding.id, kind: changes.isEmpty ? .unchanged : .changed, imageID: imageID, itemID: itemID, findingID: finding.id,
                                           title: finding.title, changes: changes, protection: protection, state: state, confidence: finding.confidence, needsReview: review))
            } else {
                out.append(TrialDifference(id: finding.id, kind: .new, imageID: imageID, itemID: nil, findingID: finding.id, title: finding.title, changes: [],
                                           protection: nil, state: state, confidence: finding.confidence, needsReview: review))
            }
        }

        // What the capture shows now and the trial did not find: reported, never removed.
        var seen: Set<String> = []
        for row in sightings {
            guard let id = try Reconciler.live(db, row["item_id"]), !found.contains(id), seen.insert(id).inserted, let item = try ItemStore.item(db, id: id) else { continue }
            out.append(TrialDifference(id: "notFound:\(imageID):\(id)", kind: .notFound, imageID: imageID, itemID: id, findingID: nil, title: item.title, changes: [],
                                       protection: nil, state: .open, confidence: nil, needsReview: false))
        }
        return out
    }

    /// What differs between an item and a proposal. A value the proposal does not have is not a difference.
    static func changes(from item: Item, to finding: Finding) -> [FieldChange] {
        var out: [FieldChange] = []
        let zone = item.timezone
        func differs(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) >= 1 } ?? true }
        func add(_ field: ItemField, _ current: JSONValue?, _ proposed: JSONValue) {
            out.append(FieldChange(field: field, current: ItemListModel.valueText(current, field: field, timezone: zone),
                                   proposed: ItemListModel.valueText(proposed, field: field, timezone: zone)))
        }
        if finding.title.trimmingCharacters(in: .whitespacesAndNewlines) != item.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            add(.title, .string(item.title), .string(finding.title))
        }
        if finding.allDay != item.allDay { add(.allDay, .bool(item.allDay), .bool(finding.allDay)) }
        if item.family == .event {
            if let start = finding.start, differs(item.start, start) { add(.start, item.start.map { .date($0) }, .date(start)) }
            if let end = finding.end, differs(item.end, end) { add(.end, item.end.map { .date($0) }, .date(end)) }
        } else {
            if let due = finding.due, differs(item.due, due) { add(.due, item.due.map { .date($0) }, .date(due)) }
            else if finding.due == nil, let start = finding.start, differs(item.start, start) { add(.start, item.start.map { .date($0) }, .date(start)) }
        }
        if let place = finding.place, !place.isEmpty, place != item.place { add(.place, item.place.map { .string($0) }, .string(place)) }
        return out
    }
}

/// One difference between two trials of the same capture (spec 008, FR-012).
public struct TrialPairDifference: Sendable, Equatable {
    public enum Kind: String, Sendable { case onlyInFirst, onlyInSecond, differs }
    public let imageID: String
    public let kind: Kind
    public let title: String
    /// First trial's value, second trial's value, for `differs`.
    public let changes: [FieldChange]
}

extension TrialComparison {
    /// The proposals of two trials side by side, capture by capture, for the captures both read. A proposal matches the other trial's when
    /// the normalised title and the date agree; one that has a partner with other values is `differs`.
    public func between(_ first: String, _ second: String) throws -> [TrialPairDifference] {
        let shared = Set(try store.readImageIDs(trialID: first)).intersection(try store.readImageIDs(trialID: second))
        var out: [TrialPairDifference] = []
        for imageID in shared.sorted() {
            let a = try store.findings(trialID: first, imageID: imageID), b = try store.findings(trialID: second, imageID: imageID)
            var unmatched = b
            for left in a {
                let key = TitleNormaliser.normalise(left.title)
                if let index = unmatched.firstIndex(where: { TitleNormaliser.normalise($0.title) == key }) {
                    let right = unmatched.remove(at: index)
                    let changes = Self.pairChanges(left, right)
                    if !changes.isEmpty { out.append(TrialPairDifference(imageID: imageID, kind: .differs, title: left.title, changes: changes)) }
                } else {
                    out.append(TrialPairDifference(imageID: imageID, kind: .onlyInFirst, title: left.title, changes: []))
                }
            }
            for right in unmatched { out.append(TrialPairDifference(imageID: imageID, kind: .onlyInSecond, title: right.title, changes: [])) }
        }
        return out
    }

    static func pairChanges(_ a: Finding, _ b: Finding) -> [FieldChange] {
        func text(_ date: Date?, _ zone: String) -> String { date.map { ItemListModel.valueText(.date($0), field: .start, timezone: zone) } ?? "none" }
        var out: [FieldChange] = []
        func same(_ x: Date?, _ y: Date?) -> Bool { switch (x, y) { case (nil, nil): true; case let (p?, q?): abs(p.timeIntervalSince(q)) < 1; default: false } }
        if !same(a.start, b.start) { out.append(FieldChange(field: .start, current: text(a.start, a.timezone), proposed: text(b.start, b.timezone))) }
        if !same(a.end, b.end) { out.append(FieldChange(field: .end, current: text(a.end, a.timezone), proposed: text(b.end, b.timezone))) }
        if !same(a.due, b.due) { out.append(FieldChange(field: .due, current: text(a.due, a.timezone), proposed: text(b.due, b.timezone))) }
        if (a.place ?? "") != (b.place ?? "") { out.append(FieldChange(field: .place, current: a.place ?? "none", proposed: b.place ?? "none")) }
        return out
    }
}
