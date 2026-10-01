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
