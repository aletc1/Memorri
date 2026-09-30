import Foundation

/// The answer structures the model is held to (ADR 0014). Changing one changes its version.
public enum ExtractionSchemas {
    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static let string: JSONValue = .object(["type": .string("string")])
    static let number: JSONValue = .object(["type": .string("number")])
    static let boolean: JSONValue = .object(["type": .string("boolean")])

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
}
