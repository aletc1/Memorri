import Foundation

public enum SchemaValidationError: Error, Sendable, Equatable {
    case notJSON
    case mismatch(String)
}

/// Checks an answer against the subset of JSON Schema that our schemas use: `type` (object, string,
/// boolean, integer, number, array), `properties`, `required`, `enum`, `items` and
/// `additionalProperties: false`. A mismatch names the path of the first problem.
public enum SchemaValidator {
    public static func validate(_ answer: String, against schema: JSONValue) -> Result<JSONValue, SchemaValidationError> {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(answer.utf8)) else { return .failure(.notJSON) }
        if let problem = check(value, schema, path: "") { return .failure(.mismatch(problem)) }
        return .success(value)
    }

    private static func check(_ value: JSONValue, _ schema: JSONValue, path: String) -> String? {
        guard case .object(let rules) = schema else { return nil }
        let here = path.isEmpty ? "answer" : path

        if case .string(let type)? = rules["type"], !matches(value, type: type) {
            return "\(here) should be \(type)"
        }
        if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
            return "\(here) is not one of the allowed values"
        }
        if case .object(let object) = value {
            if case .array(let required)? = rules["required"] {
                for case .string(let key) in required where object[key] == nil {
                    return "\(join(path, key)) is missing"
                }
            }
            let properties: [String: JSONValue]
            if case .object(let declared)? = rules["properties"] { properties = declared } else { properties = [:] }
            if case .bool(false)? = rules["additionalProperties"] {
                for key in object.keys.sorted() where properties[key] == nil { return "\(join(path, key)) is not allowed" }
            }
            for key in object.keys.sorted() {
                if let propertySchema = properties[key], let item = object[key],
                   let problem = check(item, propertySchema, path: join(path, key)) { return problem }
            }
        }
        if case .array(let items) = value, let itemSchema = rules["items"] {
            for (index, item) in items.enumerated() {
                if let problem = check(item, itemSchema, path: "\(path)[\(index)]") { return problem }
            }
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("integer", .int), ("number", .int), ("number", .double): true
        default: false
        }
    }

    private static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
}
