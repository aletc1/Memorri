import Foundation

/// Where in an item a search matched.
public enum SearchField: String, Sendable, Equatable { case title, alias, notes, place, people }

/// Text with the ranges of the words that matched.
public struct MarkedText: Sendable, Equatable {
    public let text: String
    public let marks: [Range<String.Index>]

    public init(text: String, marks: [Range<String.Index>]) { self.text = text; self.marks = marks }

    public init(_ text: String, terms: SearchQuery.Terms) { self.init(text: text, marks: SearchText.marks(of: terms, in: text)) }
}

public struct ItemHit: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: FindingKind
    public let title: MarkedText
    /// The start of an appointment, the due date of a to-do (else its start).
    public let date: Date?
    public let contextID: String?
    public let status: ItemStatus
    public let needsReview: Bool
    public let matchedIn: SearchField
    /// The text of the field that matched when it is not the title.
    public let snippet: MarkedText?
}

public struct LineHit: Sendable, Equatable {
    public let number: Int
    public let text: MarkedText
}

public struct CaptureHit: Sendable, Equatable, Identifiable {
    /// The picture's id.
    public let id: String
    public let capturedAt: Date
    public let displayName: String?
    public let windowApp: String?
    public let windowTitle: String?
    public let lines: [LineHit]
}

public struct SearchResults: Sendable, Equatable {
    public let items: [ItemHit]
    public let captures: [CaptureHit]
    public let moreItems: Bool
    public let moreCaptures: Bool
    /// Pictures that are stored but whose text is not read yet.
    public let waitingToBeAnalysed: Int

    public static let empty = SearchResults(items: [], captures: [], moreItems: false, moreCaptures: false, waitingToBeAnalysed: 0)
}

public enum SearchState: Sendable, Equatable {
    case ready
    case preparing(done: Int, total: Int)
}
