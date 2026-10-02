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

    public static let windowsSchemaVersion = "schema-windows-v1"

    /// The windows call (spec 011): for every window it was given, whether it can hold appointments, tasks or reminders and which kind of view it
    /// is, plus what the classify answer said about the capture as a whole. `keys` are the windows listed in the prompt: each entry's key is one of
    /// them and there are exactly that many entries (the answer is also checked to name each once, see `WindowsAnswer`).
    public static func windowsSchema(keys: [String]) -> JSONValue {
        let entry = object([
            "key": .object(["type": .string("string"), "enum": .array(keys.map { .string($0) })]),
            "relevant": boolean,
            "kind": .object(["type": .string("string"), "enum": .array(ScreenKind.allCases.map { .string($0.rawValue) })]),
            "confidence": number,
            "remote": boolean,
            "calendar_name": string,
        ], required: ["key", "relevant", "kind", "confidence", "remote", "calendar_name"])
        return object([
            "windows": .object(["type": .string("array"), "items": entry, "minItems": .int(keys.count), "maxItems": .int(keys.count)]),
            "application": string,
            "platform_look": string,
            "theme": string,
            "remote_session": object(["is_remote": boolean, "client": string], required: ["is_remote", "client"]),
        ], required: ["windows", "application", "platform_look", "theme", "remote_session"])
    }

    /// Month views gained `column_line` (the day label of the cell), so their schema is at version 2.
    public static func schemaVersion(for kind: ScreenKind) -> String { "schema-\(kind.rawValue)-\(kind == .calendarMonth ? "v2" : "v1")" }

    /// `{ "findings": [ ... ] }`. Every finding has a kind, a non-empty title and a list of cited line numbers (the citation check drops findings that cite none); dates
    /// and times are literal texts (the resolver turns them into instants). Week and day views add the column header
    /// line, email the time it was sent, chat the time of the message.
    public static func extractSchema(for kind: ScreenKind) -> JSONValue {
        var properties: [String: JSONValue] = [
            "kind": .object(["type": .string("string"), "enum": .array(FindingKind.allCases.map { .string($0.rawValue) })]),
            "title": .object(["type": .string("string"), "minLength": .int(1)]),
            // No minItems: a finding that cites nothing is discarded and recorded (FR-006), not a reason to reject the whole answer.
            "cited_lines": .object(["type": .string("array"), "items": integer]),
            "start_text": string, "end_text": string, "date_text": string, "due_text": string, "remind_text": string,
            "all_day": boolean,
            "people": .object(["type": .string("array"), "items": string]),
            "place": string, "notes": string,
        ]
        switch kind {
        case .calendarWeek, .calendarDay, .calendarMonth: properties["column_line"] = integer
        case .email: properties["sent_text"] = string
        case .chat: properties["message_time_text"] = string
        case .document, .other: break
        }
        let finding: JSONValue = .object(["type": .string("object"), "properties": .object(properties),
                                          "required": .array([.string("kind"), .string("title"), .string("cited_lines")])])
        return .object(["type": .string("object"),
                        "properties": .object(["findings": .object(["type": .string("array"), "items": finding])]),
                        "required": .array([.string("findings")])])
    }
}
