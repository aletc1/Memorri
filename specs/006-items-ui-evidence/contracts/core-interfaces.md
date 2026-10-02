# Core interfaces: evidence, review, editing

## Evidence (`Packages/MemorriCore/Sources/MemorriCore/Evidence/`)

```swift
public struct PixelRegion: Sendable, Equatable, Codable { public let x, y, width, height: Int }

public enum EvidenceGeometry {
    public static let maxWidth = 1600
    public static func region(lines: [PixelBox], pictureWidth: Int, pictureHeight: Int) -> PixelRegion?   // research R2; nil for no lines
    public static func outputSize(for region: PixelRegion) -> (width: Int, height: Int)
}

public struct EvidenceRecord: Sendable, Equatable, Identifiable {
    public let id, itemID: String; public let sightingID: String?; public let imageID: String
    public let capturedAt: Date; public let displayName: String?; public let title: String
    public let citedLines: [Int]; public let region: PixelRegion?; public let filePath: String?; public let reason: String?
}

public struct EvidenceWriter: Sendable {
    public init(paths: AppPaths, database: StorageDatabase, pictures: any FullPictureProviding, encoder: any ImageEncoding = HEICImageEncoder())
    public func write(imageID: String) async -> Int                 // after reconcile; replaces the picture's evidence; never throws
    public func backfill(itemID: String) async -> Int               // sightings without evidence whose picture is stored
    public func backfill(limit: Int) async -> Int                   // launch pass
}

public struct EvidenceStore: Sendable {
    public func evidence(itemID: String) throws -> [EvidenceRecord]                // newest first
    public func image(_ record: EvidenceRecord) -> CGImage?                         // the saved cut-out
    public func capture(_ record: EvidenceRecord) throws -> (picture: CGImage, lines: [RecognisedLine])?   // nil when the capture is gone
    public func totalBytes() throws -> Int64
}
```

## Review (`Reconciliation/ReviewRules.swift`)

```swift
public enum ReviewReason: String, Sendable, Codable, CaseIterable {
    case lowConfidence = "low-confidence", guessedStart = "guessed-start", guessedEnd = "guessed-end", guessedDue = "guessed-due"
    case possibleDuplicate = "possible-duplicate", changedAfterApproval = "changed-after-approval"
}
public enum ReviewRules {
    public static let level = 0.75
    public static func reasons(item: Item, chosenSources: [ItemField: ObservationSource], locked: Set<ItemField>,
                               hasOpenPossibleDuplicate: Bool, approvedValues: [ItemField: JSONValue]?, currentValues: [ItemField: JSONValue]) -> [ReviewReason]
}
```

`Item` gains `needsReview: Bool`, `reviewReasons: [ReviewReason]`, `approvedAt: Date?`. `ItemRow` is unchanged otherwise.

## Operations

```swift
extension ItemOperations {
    public func approve(_ itemID: String) throws -> OpID                       // op kind "approve"; undoable
    // edit(_:field:value:) now also validates start ≤ end and a non-empty title, and approves the item
}
public enum ItemOperationError { /* adds */ case startAfterEnd, emptyTitle }
extension ItemStore {
    public func reviewCount(contextID: String??) throws -> Int
    public func observeReviewCount() -> AsyncStream<Int>
}
```

## List model

`ItemKindFilter` gains `.reminders` (and `.tasks` means task and deadline). `ItemFilter` gains `scope: .all | .inbox`. `ItemListModel` gains `reviewText(_ reasons:) -> [String]`, `approvalText(_ item:) -> String` (`Needs review`, `Approved`, `Approved by you`), and `parse(_ text: String, field: ItemField, timezone: String) -> Result<JSONValue, EditError>` for the editors.

## As built (differences from the plan above)

- `ReviewReason` is declared in `Reconciliation/Item.swift`. `ReviewRules` also has `approvedFields`, `snapshot(of:)` (what an approval stores and what a later state is compared with) and the stored form of a snapshot. An item with an approval snapshot is judged only on `changed-after-approval`: the approval covers the doubts that were there. Dismissed and merged items never need review.
- `ItemStore`: `items(status:kinds:contextID:review:)` and `observeItems(...review:)` take a review filter; `reviewCount(contextID:)` defaults to every context. Internal: `refreshReview` (review columns only, used by migration `v6-review`), `approve`, `setApprovalValues`, `clearApproval`, `recomputeReview`.
- Migration `v6-review` follows `v6` and computes the review columns of existing items; `v6` itself only changes the schema.
- `OperationKind.approve`; `ItemState` has optional `approvedAt` and `approvedValues`.
- `ItemOperations.edit`: a blank title throws `emptyTitle`, a start after the end (or an end before the start) throws `startAfterEnd`; `null` clears `end`, `due`, `remind`, `place` and `notes` as a locked empty value (`FieldResolver` treats a locked `null` as "cleared"); a start, title, all-day flag and people list always have a value; title and people are normalised; the edit approves in the same operation.
- `ItemFilter(kind:context:scope:showDismissed:)` with `ItemScope` (`.all`, `.inbox`, `.approved`); `ItemKindFilter` is `all`, `appointments`, `tasks` (task and deadline), `reminders` and has `kinds`.
- `ItemListModel` also has `inboxCount`, `emptyText(scope:)`, `canApprove`, `editText`, `EditError` (with `message`), `provenance(_:timezone:)` and `sourceSightingID(_:)` (FR-005). `editText` (not `valueText`) is the text an editor starts with and round-trips through `parse`.
