import Foundation
import GRDB
import os

public enum ReconcileError: Error, Equatable {
    /// The picture has no analysis to reconcile.
    case noAnalysis
}

/// What the analyse job calls once a picture's analysis is stored.
public protocol ImageReconciling: Sendable {
    func reconcile(imageID: String) async -> ReconcileSummary
}

/// What reconciling one picture did.
public struct ReconcileSummary: Sendable, Equatable {
    public var created = 0
    public var merged = 0
    public var possibleDuplicates = 0
    public var judged = 0
    /// Candidate items a finding was compared with (the pairs scored).
    public var compared = 0
    /// The items this reconcile created, for the notice of new items (spec 010).
    public var createdItemIDs: [String] = []
    public var error: String?

    public init(created: Int = 0, merged: Int = 0, possibleDuplicates: Int = 0, judged: Int = 0, compared: Int = 0, error: String? = nil) {
        self.created = created; self.merged = merged; self.possibleDuplicates = possibleDuplicates; self.judged = judged; self.compared = compared; self.error = error
    }
}

/// Where each finding of a picture goes. Made without writing (it may call the local models), applied in one transaction.
public struct ReconcilePlan: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case existing(itemID: String)
        case newItem
        /// The item the earlier step of this plan made or joined.
        case sameAsStep(Int)
        case newWithPossibleDuplicate(of: String)
    }

    public struct Step: Sendable, Equatable {
        public let findingID: String
        public let target: Target
        public let scores: MatchScores?
        public let rule: String
        /// The item the decision compared with, for the stored explanation.
        public let candidate: String?
    }

    public let imageID: String
    public let steps: [Step]
    public let judged: Int
    public let compared: Int
}

/// Turns the findings of an analysed picture into sightings of items (ADR 0020): candidates by context, kind family and day; scores
/// from text, time and the title embeddings; the judge only for the uncertain band; one transaction to apply.
public struct Reconciler: ImageReconciling {
    private static let logger = Logger(subsystem: MemorriCore.subsystem, category: "reconcile")
    private static let maxJudgedPerFinding = 2

    let database: StorageDatabase
    let judge: any MeaningJudging
    let thresholds: ReconcileThresholds
    let now: @Sendable () -> Date

    public init(database: StorageDatabase, judge: any MeaningJudging, thresholds: ReconcileThresholds = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.judge = judge; self.thresholds = thresholds; self.now = now
    }

    /// Plan and apply. Never throws: a failure is stored on the picture (`reconcile_error`) and returned in the summary.
    public func reconcile(imageID: String) async -> ReconcileSummary {
        let started = ContinuousClock.now
        do {
            let plan = try await plan(imageID: imageID)
            var summary = try apply(plan)
            summary.judged = plan.judged
            summary.compared = plan.compared
            let ms = started.duration(to: .now).components.seconds * 1000 + started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000
            Self.logger.info("reconciled image=\(imageID, privacy: .public) findings=\(plan.steps.count) created=\(summary.created) merged=\(summary.merged) possible=\(summary.possibleDuplicates) judged=\(summary.judged) ms=\(ms)")
            return summary
        } catch {
            let reason = Self.reason(for: error)
            Self.logger.error("reconcile failed image=\(imageID, privacy: .public) reason=\(reason, privacy: .public)")
            let stamp = now()
            try? await database.pool.write { db in
                try db.execute(sql: "UPDATE image_analysis SET reconcile_error = ? WHERE image_id = ?", arguments: [reason, imageID])
                _ = stamp
            }
            return ReconcileSummary(error: reason)
        }
    }

    private static func reason(for error: Error) -> String {
        if error as? ReconcileError == .noAnalysis { return "no analysis" }
        if error is DatabaseError { return "database error" }
        return "reconcile failed"
    }

    // MARK: Plan

    struct Candidate {
        enum Key: Hashable { case item(String), step(Int) }
        let key: Key
        let itemID: String?
        let title: String
        var titles: [String]
        var spans: [TimeSpan]
        let lastSeen: Date
    }

    struct Earlier { let sightingID: String; let itemID: String; let itemContext: String?; let title: String; let when: Date? }

    struct Snapshot {
        var findings: [Finding]
        var context: String?
        var contextName: String?
        var earlier: [Earlier]
        var candidates: [[Candidate]]
        var keepApart: Set<[String]>
    }

    public func plan(imageID: String) async throws -> ReconcilePlan { try await plan(imageID: imageID, findings: nil) }

    /// The plan for `findings` instead of the picture's stored ones (a dry run over a reprocessing trial's proposals, spec 008): the same
    /// matching against the items and against what this picture already shows, and nothing written.
    public func plan(imageID: String, findings proposals: [Finding]?) async throws -> ReconcilePlan {
        let snapshot = try await database.pool.read { try Self.snapshot($0, imageID: imageID, findings: proposals) }
        let canEmbed = await judge.canEmbed
        let canJudge = await judge.canJudge
        var steps: [ReconcilePlan.Step] = []
        var judged = 0
        var compared = 0
        var usedEarlier: Set<String> = []
        var extra: [Candidate.Key: Candidate] = [:]            // what decided findings added to a candidate
        var created: [Candidate] = []                          // items this plan makes
        var claimed: [String: Set<Candidate.Key>] = [:]        // what earlier findings of this picture already joined or made, by window (research R7)

        for (index, finding) in snapshot.findings.enumerated() {
            let span = Self.span(of: finding)
            let normal = TitleNormaliser.normalise(finding.title)
            // Two windows of one picture may show the same event, so a finding only avoids what findings of its own window took.
            let window = finding.windowKey ?? ""

            // Rule 0: a finding this picture already had stays with its item.
            // (Not when the picture has since been given another context: then the finding is matched afresh.)
            if let earlier = snapshot.earlier.first(where: { !usedEarlier.contains($0.sightingID) && $0.itemContext == snapshot.context
                                                             && TitleNormaliser.normalise($0.title) == normal && Self.sameInstant($0.when, span.start) }) {
                usedEarlier.insert(earlier.sightingID)
                claimed[window, default: []].insert(.item(earlier.itemID))
                steps.append(.init(findingID: finding.id, target: .existing(itemID: earlier.itemID), scores: nil, rule: "same-picture", candidate: earlier.itemID))
                Self.remember(.item(earlier.itemID), finding: finding, span: span, into: &extra)
                continue
            }
            let blockedBy = snapshot.earlier.first { $0.itemContext == snapshot.context && TitleNormaliser.normalise($0.title) == normal }?.itemID

            // Candidates: the stored ones for this finding, plus the items earlier steps made.
            var pool = snapshot.candidates[index].map { c -> Candidate in
                var merged = c
                if let more = extra[c.key] { merged.titles += more.titles; merged.spans += more.spans }
                return merged
            }
            pool += created.map { c in
                var merged = c
                if let more = extra[c.key] { merged.titles += more.titles; merged.spans += more.spans }
                return merged
            }
            struct Scored { var candidate: Candidate; var scores: MatchScores; var decision: MatchDecision; var combined: Double }
            var scored: [Scored] = []
            for candidate in pool {
                if let id = candidate.itemID, let blockedBy, snapshot.keepApart.contains([id, blockedBy].sorted()) { continue }
                let time = candidate.spans.map { TimeAgreement.score(span, $0) }.max() ?? 0
                if time == 0 { continue }
                let text = TitleSimilarity.best(of: normal, against: candidate.titles).value
                let scores = MatchScores(text: text, time: time)
                scored.append(Scored(candidate: candidate, scores: scores, decision: MatchScorer.decide(scores, undated: span.start == nil, thresholds: thresholds),
                                     combined: text * 0.6 + time * 0.4))
            }
            compared += scored.count
            scored.sort { $0.combined != $1.combined ? $0.combined > $1.combined : $0.candidate.lastSeen > $1.candidate.lastSeen }

            // Meaning of the titles, only where it can change the answer.
            if canEmbed {
                let needed = scored.filter { $0.decision == .uncertain || $0.decision == .new(rule: "different") }
                if !needed.isEmpty,
                   let vectors = try? await judge.embeddings(for: Array(Set([normal] + needed.flatMap(\.candidate.titles)))) {
                    let titles = Array(Set([normal] + needed.flatMap(\.candidate.titles)))
                    let byTitle = Dictionary(zip(titles, vectors), uniquingKeysWith: { first, _ in first })
                    for i in scored.indices where scored[i].decision == .uncertain || scored[i].decision == .new(rule: "different") {
                        let cosines = scored[i].candidate.titles.compactMap { Self.cosine(byTitle[normal], byTitle[$0]) }
                        if let best = cosines.max() {
                            scored[i].scores.cosine = best
                            scored[i].decision = MatchScorer.decide(scored[i].scores, undated: span.start == nil, thresholds: thresholds)
                        }
                    }
                }
            }

            let step: ReconcilePlan.Step
            if let hit = scored.first(where: { if case .merge = $0.decision { true } else { false } }), case .merge(let rule) = hit.decision {
                step = .init(findingID: finding.id, target: Self.target(of: hit.candidate), scores: hit.scores, rule: rule, candidate: hit.candidate.itemID)
            } else {
                let uncertain = scored.filter { $0.decision == .uncertain }
                // A window shows each event once: when another finding of this window already joined or made a candidate, a finding with
                // another title is a different event and is not sent to the judge (the small reranker says yes to "Sprint review" and
                // "Sprint retrospective" at the same time). Equal or truncated titles still merge by text.
                let judgeable = uncertain.filter { !(claimed[window]?.contains($0.candidate.key) ?? false) }
                let sameFrame = !uncertain.isEmpty && judgeable.isEmpty
                var outcome: ReconcilePlan.Step?
                var asked = 0
                var lastAnswer: MatchScores?
                // Without a date the judge has nothing but the titles, and the small reranker says yes to "invoice" and "report":
                // an undated pair in the uncertain band is flagged for the user instead (research R7).
                let undated = span.start == nil
                if canJudge && !undated {
                    for entry in judgeable.prefix(Self.maxJudgedPerFinding) {
                        guard let p = try? await judge.sameEvent(Self.judged(finding, span, context: snapshot.contextName), Self.judged(entry.candidate, context: snapshot.contextName)) else { break }
                        asked += 1
                        var withRerank = entry.scores; withRerank.rerank = p
                        lastAnswer = withRerank
                        if case .merge(let rule) = MatchScorer.decideAfterRerank(withRerank, thresholds: thresholds) {
                            outcome = .init(findingID: finding.id, target: Self.target(of: entry.candidate), scores: withRerank, rule: rule, candidate: entry.candidate.itemID)
                            break
                        }
                    }
                }
                judged += asked
                if let outcome { step = outcome }
                else if let best = (sameFrame ? uncertain : judgeable).first {
                    // Judged "no" (a new item) or could not be judged (a new item flagged as a possible duplicate).
                    let answered = canJudge && asked > 0
                    let scores = answered ? (lastAnswer ?? best.scores) : best.scores
                    let rule = answered ? "rerank-no" : (undated ? "undated-uncertain" : (sameFrame ? "same-picture-different" : "judge-unavailable"))
                    let target: ReconcilePlan.Target = !answered && !sameFrame && best.candidate.itemID != nil ? .newWithPossibleDuplicate(of: best.candidate.itemID!) : .newItem
                    step = .init(findingID: finding.id, target: target, scores: scores, rule: rule, candidate: best.candidate.itemID)
                } else {
                    let rule = scored.first.flatMap { entry -> String? in if case .new(let r) = entry.decision { r } else { nil } } ?? "no-candidate"
                    step = .init(findingID: finding.id, target: .newItem, scores: scored.first?.scores, rule: rule, candidate: nil)
                }
            }
            steps.append(step)
            switch step.target {
            case .existing(let id): claimed[window, default: []].insert(.item(id))
            case .sameAsStep(let n): claimed[window, default: []].insert(.step(n))
            case .newItem, .newWithPossibleDuplicate: claimed[window, default: []].insert(.step(index))
            }
            switch step.target {
            case .existing(let id): Self.remember(.item(id), finding: finding, span: span, into: &extra)
            case .sameAsStep(let n): Self.remember(.step(n), finding: finding, span: span, into: &extra)
            case .newItem, .newWithPossibleDuplicate:
                created.append(Candidate(key: .step(index), itemID: nil, title: finding.title, titles: [normal], spans: [span], lastSeen: .distantFuture))
            }
        }
        return ReconcilePlan(imageID: imageID, steps: steps, judged: judged, compared: compared)
    }

    private static func target(of candidate: Candidate) -> ReconcilePlan.Target {
        switch candidate.key {
        case .item(let id): .existing(itemID: id)
        case .step(let n): .sameAsStep(n)
        }
    }

    private static func remember(_ key: Candidate.Key, finding: Finding, span: TimeSpan, into extra: inout [Candidate.Key: Candidate]) {
        var entry = extra[key] ?? Candidate(key: key, itemID: nil, title: "", titles: [], spans: [], lastSeen: .distantPast)
        entry.titles.append(TitleNormaliser.normalise(finding.title)); entry.spans.append(span)
        extra[key] = entry
    }

    static func span(of finding: Finding) -> TimeSpan {
        let family = KindFamily(kind: finding.kind)
        return TimeSpan(start: family == .event ? finding.start : (finding.due ?? finding.start), end: family == .event ? finding.end : nil,
                        allDay: finding.allDay, timezone: finding.timezone, family: family)
    }

    private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): abs(x.timeIntervalSince(y)) < 1
        default: false
        }
    }

    private static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i]) }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func when(_ span: TimeSpan) -> String {
        guard let start = span.start else { return "no date" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: span.timezone) ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = span.allDay ? "EEE d MMM" : "EEE d MMM HH:mm"
        var text = formatter.string(from: start)
        if let end = span.end, !span.allDay { formatter.dateFormat = "HH:mm"; text += "-" + formatter.string(from: end) }
        return text
    }

    private static func judged(_ finding: Finding, _ span: TimeSpan, context: String?) -> JudgedSighting {
        JudgedSighting(title: finding.title, when: when(span), context: context)
    }

    private static func judged(_ candidate: Candidate, context: String?) -> JudgedSighting {
        JudgedSighting(title: candidate.title, when: candidate.spans.first.map(when) ?? "no date", context: context)
    }
}
