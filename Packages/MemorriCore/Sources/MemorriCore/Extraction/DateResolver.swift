import Foundation

/// A date or time field after resolution. Until the resolver exists (spec 004, user story 5) every text stays as written.
public struct ResolvedValue: Sendable, Equatable {
    public let date: Date?
    public let allDay: Bool
    public let provenance: FieldProvenance?
    public let unresolvedText: String?
}

public enum DateResolver {
    /// Placeholder: keeps the text as the picture wrote it, flagged unresolved, and sets no date.
    public static func resolve(text: String, field: String) -> ResolvedValue {
        ResolvedValue(date: nil, allDay: false, provenance: nil, unresolvedText: text)
    }
}
