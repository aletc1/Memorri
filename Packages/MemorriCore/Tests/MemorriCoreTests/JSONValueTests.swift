import Foundation
import Testing
@testable import MemorriCore

@Suite struct JSONValueTests {
    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func decodesEveryKindOfValue() throws {
        let value = try decode(#"{"s":"x","i":3,"d":2.5,"t":true,"f":false,"n":null,"a":[1,"b"],"o":{"k":1}}"#)
        guard case .object(let object) = value else { Issue.record("expected an object"); return }
        #expect(object["s"] == .string("x"))
        #expect(object["i"] == .int(3))
        #expect(object["d"] == .double(2.5))
        #expect(object["t"] == .bool(true) && object["f"] == .bool(false))
        #expect(object["n"] == .null)
        #expect(object["a"] == .array([.int(1), .string("b")]))
        #expect(object["o"] == .object(["k": .int(1)]))
    }

    @Test func aBooleanIsNotAnInteger() throws {
        #expect(try decode("true") == .bool(true))
        #expect(try decode("1") == .int(1))
    }

    @Test func encodingAndDecodingRoundTrip() throws {
        let value = JSONValue.object(["a": .array([.int(1), .double(1.5), .null]), "b": .string("é \"q\""), "c": .bool(false)])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func anIntegerStaysAnIntegerInTheEncodedText() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(JSONValue.object(["n": .int(2048), "t": .double(0)])), as: UTF8.self)
        #expect(text == #"{"n":2048,"t":0}"#)
    }
}
