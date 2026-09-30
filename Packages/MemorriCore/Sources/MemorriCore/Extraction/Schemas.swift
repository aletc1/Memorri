import Foundation

/// The answer structures the model is held to (ADR 0014). Changing one changes its version.
public enum ExtractionSchemas {
    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static let string: JSONValue = .object(["type": .string("string")])
    static let number: JSONValue = .object(["type": .string("number")])
    static let integer: JSONValue = .object(["type": .string("integer")])
    static let boolean: JSONValue = .object(["type": .string("boolean")])

    public static let classifySchemaVersion = "schema-classify-v1"

    /// Which kind of screen, how sure, and what the picture looks like (used for tags).
    public static let classifySchema: JSONValue = object([
        "screen_kind": .object(["type": .string("string"), "enum": .array(ScreenKind.allCases.map { .string($0.rawValue) })]),
        "kind_confidence": number,
        "application": string,
        "platform_look": string,
        "remote_session": object(["is_remote": boolean, "client": string], required: ["is_remote", "client"]),
        "theme": string,
        "calendar_name": string,
    ], required: ["screen_kind", "kind_confidence", "application", "platform_look", "remote_session", "theme", "calendar_name"])

    public static func schemaVersion(for kind: ScreenKind) -> String { "schema-\(kind.rawValue)-v1" }

    /// `{ "findings": [ ... ] }`. Every finding has a kind, a non-empty title and at least one cited line number; dates
    /// and times are literal texts (the resolver turns them into instants). Week and day views add the column header
    /// line, email the time it was sent, chat the time of the message.
    public static func extractSchema(for kind: ScreenKind) -> JSONValue {
        var properties: [String: JSONValue] = [
            "kind": .object(["type": .string("string"), "enum": .array(FindingKind.allCases.map { .string($0.rawValue) })]),
            "title": .object(["type": .string("string"), "minLength": .int(1)]),
            "cited_lines": .object(["type": .string("array"), "minItems": .int(1), "items": integer]),
            "start_text": string, "end_text": string, "date_text": string, "due_text": string, "remind_text": string,
            "all_day": boolean,
            "people": .object(["type": .string("array"), "items": string]),
            "place": string, "notes": string,
        ]
        switch kind {
        case .calendarWeek, .calendarDay: properties["column_line"] = integer
        case .email: properties["sent_text"] = string
        case .chat: properties["message_time_text"] = string
        case .calendarMonth, .document, .other: break
        }
        let finding: JSONValue = .object(["type": .string("object"), "properties": .object(properties),
                                          "required": .array([.string("kind"), .string("title"), .string("cited_lines")])])
        return .object(["type": .string("object"),
                        "properties": .object(["findings": .object(["type": .string("array"), "items": finding])]),
                        "required": .array([.string("findings")])])
    }
}
