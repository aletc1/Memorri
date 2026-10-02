# Core interfaces: search (`Packages/MemorriCore/Sources/MemorriCore/Search/`)

```swift
public struct SearchQuery: Sendable, Equatable {
    public enum Kinds: Sendable, Equatable { case appointments, tasks, reminders, captures }
    public enum Context: Sendable, Equatable { case any, none, one(String) }
    public var text: String                      // as typed
    public var kinds: Set<Kinds>                 // empty = everything
    public var context: Context
    public var dates: ClosedRange<Date>?
    public var includeDismissed: Bool
    public var terms: Terms { get }              // parsed
    public struct Terms: Sendable, Equatable { public var words: [String]; public var phrases: [[String]]; public var excluded: [String] }
    public var isSearchable: Bool { get }        // a positive term and at least two letters
    public var matchExpression: String? { get }  // quoted, prefix on the last word, AND / NOT; nil when not searchable
}

public enum SearchField: String, Sendable { case title, alias, notes, place, people }
public struct MarkedText: Sendable, Equatable { public let text: String; public let marks: [Range<String.Index>] }

public struct ItemHit: Sendable, Equatable, Identifiable {
    public let id: String; public let kind: ItemKind; public let title: MarkedText; public let date: Date?
    public let contextID: String?; public let status: ItemStatus; public let needsReview: Bool
    public let matchedIn: SearchField; public let snippet: MarkedText?
}
public struct LineHit: Sendable, Equatable { public let number: Int; public let text: MarkedText }
public struct CaptureHit: Sendable, Equatable, Identifiable {
    public let id: String                        // image id
    public let capturedAt: Date; public let displayName: String?
    public let windowApp: String?; public let windowTitle: String?
    public let lines: [LineHit]
}
public struct SearchResults: Sendable, Equatable {
    public let items: [ItemHit]; public let captures: [CaptureHit]
    public let moreItems: Bool; public let moreCaptures: Bool
    public let waitingToBeAnalysed: Int          // captures not read yet, for the empty message
}

public enum SearchState: Sendable, Equatable { case ready, preparing(done: Int, total: Int) }

public struct SearchService: Sendable {
    public init(database: StorageDatabase)
    public func search(_ query: SearchQuery, itemLimit: Int = 20, captureLimit: Int = 20, itemOffset: Int = 0, captureOffset: Int = 0) async throws -> SearchResults
    public func itemIDs(matching query: SearchQuery) async throws -> [String]    // ranked, for the Items window field
    public func lines(imageID: String, matching query: SearchQuery) async throws -> [LineHit]   // all matching lines, for the capture viewer
}

public struct SearchIndex: Sendable {
    public static let version = 1
    public init(database: StorageDatabase)
    public func state() throws -> SearchState
    public func prepare(progress: @Sendable (SearchState) -> Void) async throws   // no-op when current; else rebuild in batches
    public func rebuild() throws                                                  // all in one go (tests, repair)
    static func writeCapture(_ db: Database, imageID: String, lines: [RecognisedLine]) throws   // used by OCRStore.save
}
```

## Notes
- `search` throws only for a closed or broken database, never for typed text.
- `itemIDs` honours kinds (items only), context, dates and `includeDismissed`.
- Items window: `ItemsViewModel` takes `searchText`; the matching ids restrict `ItemListModel.visible`.
- Logging: category `search`, counts and milliseconds only.
