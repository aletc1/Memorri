import Foundation
import Testing
@testable import MemorriCore

@Suite struct SchemaValidatorTests {
    /// The schema of the model test (`test-v1`).
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "description": .object(["type": .string("string")]),
            "contains_text": .object(["type": .string("boolean")]),
            "text_sample": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("description"), .string("contains_text"), .string("text_sample")]),
        "additionalProperties": .bool(false),
    ])

    private func result(_ answer: String, _ schema: JSONValue? = nil) -> Result<JSONValue, SchemaValidationError> {
        SchemaValidator.validate(answer, against: schema ?? self.schema)
    }

    private func isMismatch(_ result: Result<JSONValue, SchemaValidationError>, mentioning word: String? = nil) -> Bool {
        if case .failure(.mismatch(let message)) = result { return word.map { message.contains($0) } ?? true }
        return false
    }

    @Test func acceptsAnExactMatch() throws {
        let answer = #"{"description":"A calendar","contains_text":true,"text_sample":"Team sync"}"#
        let value = try result(answer).get()
        guard case .object(let object) = value else { Issue.record("expected an object"); return }
        #expect(object["contains_text"] == .bool(true))
    }

    @Test func rejectsTextThatIsNotJSON() {
        #expect(result("this is definitely not json") == .failure(.notJSON))
        #expect(result("") == .failure(.notJSON))
        #expect(result(#"{"description": "unterminated"#) == .failure(.notJSON))
    }

    @Test func rejectsAMissingRequiredKey() {
        #expect(isMismatch(result(#"{"description":"x","contains_text":true}"#), mentioning: "text_sample"))
    }

    @Test func rejectsAWrongType() {
        #expect(isMismatch(result(#"{"description":"x","contains_text":"yes","text_sample":"y"}"#), mentioning: "contains_text"))
        #expect(isMismatch(result(#"{"description":3,"contains_text":true,"text_sample":"y"}"#), mentioning: "description"))
    }

    @Test func rejectsAnExtraKeyWhenAdditionalPropertiesIsFalse() {
        #expect(isMismatch(result(#"{"description":"x","contains_text":true,"text_sample":"y","extra":1}"#), mentioning: "extra"))
    }

    @Test func allowsAnExtraKeyWhenTheSchemaDoesNotForbidIt() throws {
        let open: JSONValue = .object(["type": .string("object"), "properties": .object(["a": .object(["type": .string("integer")])])])
        _ = try result(#"{"a":1,"b":2}"#, open).get()
    }

    @Test func rejectsAValueOutsideAnEnum() throws {
        let enumSchema: JSONValue = .object(["type": .string("object"), "required": .array([.string("kind")]),
            "properties": .object(["kind": .object(["type": .string("string"), "enum": .array([.string("a"), .string("b")])])])])
        _ = try result(#"{"kind":"a"}"#, enumSchema).get()
        #expect(isMismatch(result(#"{"kind":"c"}"#, enumSchema), mentioning: "kind"))
    }

    @Test func checksArrayItems() throws {
        let arraySchema: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("integer")])])
        _ = try result("[1,2,3]", arraySchema).get()
        #expect(isMismatch(result(#"[1,"two"]"#, arraySchema)))
    }

    @Test func distinguishesIntegerFromNumberAndBoolean() throws {
        let number: JSONValue = .object(["type": .string("number")])
        let integer: JSONValue = .object(["type": .string("integer")])
        _ = try result("1.5", number).get()
        _ = try result("2", number).get()
        #expect(isMismatch(result("1.5", integer)))
        #expect(isMismatch(result("true", integer)))
    }

    @Test func rejectsANonObjectWhenTheSchemaSaysObject() {
        #expect(isMismatch(result("[1,2]")))
        #expect(isMismatch(result(#""text""#)))
        #expect(isMismatch(result("null")))
    }

    @Test func nestedErrorsNameThePath() {
        let nested: JSONValue = .object(["type": .string("object"), "required": .array([.string("a")]),
            "properties": .object(["a": .object(["type": .string("object"), "required": .array([.string("b")]),
                "properties": .object(["b": .object(["type": .string("string")])])])])])
        #expect(isMismatch(result(#"{"a":{"b":1}}"#, nested), mentioning: "a.b"))
    }
}
