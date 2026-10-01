# Core interfaces: reconciliation

Types in `Packages/MemorriCore/Sources/MemorriCore/Reconciliation/`. All are `Sendable`; stores take the existing `StorageDatabase`. Pure types (normaliser, similarity, time, scorer, resolver) have no I/O and are tested table-first.

## Values

```swift
public enum KindFamily: String, Sendable { case event, todo }           // appointment → event; task, reminder, deadline → todo
public enum ItemStatus: String, Sendable { case active, dismissed, merged }
public enum ItemField: String, Sendable, CaseIterable { case title, start, end, allDay = "all_day", due, remind, people, place, notes }
public enum ObservationSource: String, Sendable { case read, inferred, user }

public struct Item: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: FindingKind; public var status: ItemStatus; public var mergedInto: String?
    public var contextID: String?; public var title: String; public var allDay: Bool
    public var start: Date?; public var end: Date?; public var due: Date?; public var remind: Date?
    public var timezone: String; public var people: [String]; public var place: String?; public var notes: String?
    public var confidence: Double; public var userTouched: Bool; public var firstSeen: Date; public var lastSeen: Date
    public var family: KindFamily { get }
}

public struct ItemObservation: Sendable, Equatable { public let id, itemID: String; public let sightingID: String?
    public let field: ItemField; public let value: JSONValue; public let source: ObservationSource
    public let confidence: Double; public let observedAt: Date }
```

## Matching (pure)

```swift
public enum TitleNormaliser { public static func normalise(_ title: String) -> String }

public enum TitleSimilarity {
    public enum Relation: Sendable { case equal, truncation, fuzzy }
    public static func score(_ a: String, _ b: String) -> (value: Double, relation: Relation)   // normalised inputs, research R6
    public static func best(of title: String, against others: [String]) -> (value: Double, relation: Relation)   // every alias counts
}

public struct TimeSpan: Sendable, Equatable { public let start: Date?; public let end: Date?; public let allDay: Bool; public let timezone: String; public let family: KindFamily }

public enum TimeAgreement {
    public static func dayKey(_ date: Date?, timezone: String) -> String?
    public static func isCandidate(_ a: TimeSpan, _ b: TimeSpan) -> Bool          // research R5: score > 0
    public static func score(_ a: TimeSpan, _ b: TimeSpan) -> Double
}

public struct MatchScores: Sendable, Equatable, Codable { public var text: Double; public var time: Double; public var cosine: Double?; public var rerank: Double? }

public enum MatchDecision: Sendable, Equatable { case merge(rule: String), new(rule: String), uncertain }

public struct ReconcileThresholds: Sendable, Equatable, Codable {  // research R7; the measured values are in ADR 0020
    public static let `default`: ReconcileThresholds
    public var mergeText = 0.9, minTime = 0.5, sameTime = 0.8, newText = 0.5, newCosine = 0.88, rerankYes = 0.95, undatedMergeText = 0.9, undatedRerankText = 0.7
}

public enum MatchScorer {
    public static func decide(_ scores: MatchScores, undated: Bool, thresholds: ReconcileThresholds) -> MatchDecision   // before the reranker
    public static func decideAfterRerank(_ scores: MatchScores, thresholds: ReconcileThresholds) -> MatchDecision      // rerank nil → .new(rule: "judge-unavailable")
}
```

## Meaning judge

```swift
public protocol MeaningJudging: Sendable {
    func embeddings(for titles: [String]) async throws -> [[Float]]             // normalised titles in, vectors out, same order
    func sameEvent(_ a: JudgedSighting, _ b: JudgedSighting) async throws -> Double   // probability of yes
    var canEmbed: Bool { get async }                                           // an embedding model is chosen and installed
    var canJudge: Bool { get async }                                           // a reranker is chosen and installed
}
public struct JudgedSighting: Sendable { public let title: String; public let when: String; public let context: String? }

public final class OllamaMeaningJudge: MeaningJudging {
    public init(client: OllamaClient, embeddingModel: String?, rerankerModel: String?, database: StorageDatabase?, timeout: TimeInterval = 20, now: ...)
    public static let instructionVersion = "rerank-v2"     // asks both orders and keeps the lower probability; vectors cached in title_embeddings
}
public final class LiveMeaningJudge: MeaningJudging   // the app's judge: rebuilt from OllamaSettings and the installed models when they change, and every minute
public struct NoMeaningJudge: MeaningJudging   // text and time only
```

`OllamaClient` gains `embed(model:inputs:timeout:) -> [[Float]]` (`/api/embed`) and `generateNextTokenLogprobs(model:prompt:timeout:) -> [(token: String, logprob: Double)]` (`/api/generate`, `raw`, `num_predict: 1`, `logprobs`, `top_logprobs: 5`). Both go through the existing loopback-only transport. Missing models are found with the existing `models()` list; a model that is not installed makes the judge use only what is installed.

## Field resolution (pure)

```swift
public enum FieldResolver {
    public static func resolve(_ observations: [ItemObservation], locks: [ItemField: String]) -> ResolvedFields   // research R9
}
public struct ResolvedFields: Sendable, Equatable { /* one value per ItemField plus the chosen observation id per field, the aliases */ }
```

## Reconciler

```swift
public struct ReconcilePlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable { public let findingID: String; public let target: Target; public let scores: MatchScores?; public let rule: String; public let candidate: String? }
    public enum Target: Sendable, Equatable { case existing(itemID: String), newItem, sameAsStep(Int), newWithPossibleDuplicate(of: String) }
    public let imageID: String; public let steps: [Step]; public let judged: Int; public let compared: Int
}

public protocol ImageReconciling: Sendable { func reconcile(imageID: String) async -> ReconcileSummary }

public struct Reconciler: ImageReconciling {
    public init(database: StorageDatabase, judge: any MeaningJudging, thresholds: ReconcileThresholds = .default, now: @escaping @Sendable () -> Date = { Date() })
    public func plan(imageID: String) async throws -> ReconcilePlan                  // reads; may call the judge
    public func apply(_ plan: ReconcilePlan) throws -> ReconcileSummary              // one write transaction, research R1, R2
    public func reconcile(imageID: String) async -> ReconcileSummary                 // plan + apply; never throws, records reconcile_error
}
public struct ReconcileSummary: Sendable, Equatable { public var created, merged, possibleDuplicates, judged, compared: Int; public var error: String? }   // compared = candidate pairs scored
```

`ImageAnalysisJob` calls `reconcile(imageID:)` after `AnalysisResultStore.save`. Its outcome never changes the job outcome.

## Items and operations

```swift
public struct ItemStore: Sendable {
    public func items(status: Set<ItemStatus>, kinds: Set<KindFamily>?, contextID: String??) throws -> [ItemRow]   // with sighting counts
    public func detail(itemID: String) throws -> ItemDetail      // observations, sightings with captures, aliases, locks, ops, possible duplicates
    public func observeItems(status: Set<ItemStatus>, kinds: Set<KindFamily>? = nil, contextID: String?? = nil) -> AsyncStream<[ItemRow]>   // GRDB ValueObservation for the window
    public func sweep(at: Date = Date()) throws -> Int          // research R11; returns items removed
}

public struct ItemOperations: Sendable {
    public func merge(_ keep: String, _ other: String, lockChoices: [ItemField: String] = [:]) throws -> OpID   // throws .needsLockChoice([ItemField])
    public func split(_ itemID: String, sightings: [String]) throws -> (op: OpID, newItem: String)
    public func dismiss(_ itemID: String) throws -> OpID
    public func restore(_ itemID: String) throws -> OpID
    public func edit(_ itemID: String, field: ItemField, value: JSONValue) throws -> OpID
    public func unlock(_ itemID: String, field: ItemField) throws -> OpID
    public func changeContext(imageID: String, to contextID: String?) async throws -> OpID   // research R12a
    public func markDifferent(_ a: String, _ b: String) throws -> OpID      // clears a possible duplicate, writes keep_apart
    public func undo(_ op: OpID) async throws -> UndoResult                  // research R10; async because undoing a context change reconciles again
}

public struct OperationLog: Sendable {
    public func operation(id: String) throws -> OperationRecord?
    public func ops(forItem itemID: String) throws -> [OperationSummary]     // newest first, an item's History
    public func recent(limit: Int = 100) throws -> [OperationSummary]        // all items, newest first; the window's Undo last picks from these
}

/// The window's logic, testable without views: filters, order, row text, which buttons are enabled, the lock-choice sheet.
public enum ItemListModel { static func visible(_:filter:), rowText(_:contextName:), dateText(_:), canMerge(_:), statusAction(for:), canSplit(checked:of:), undoTarget(in:), lockChoices(for:keep:other:) }
public enum UndoResult: Sendable, Equatable { case undone(OpID), partly(OpID, reason: String), impossible(reason: String) }
public typealias OpID = String
```

`CleanupService.delete` (which the retention run also uses) calls `ItemStore.sweep()` after deleting.
