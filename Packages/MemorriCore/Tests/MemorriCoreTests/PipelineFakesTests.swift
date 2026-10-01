import Foundation
import Testing
@testable import MemorriCore

@Suite struct PipelineFakesTests {
    private func request(schema: JSONValue) -> ChatRequest {
        ChatRequest(model: "m", systemPrompt: nil, prompt: "p", picture: Data([1]), picturePlaceholder: "[picture]", schema: schema,
                    useNativeFormat: true, think: .omitted, temperature: 0, timeout: 5)
    }

    @Test func theFakeModelAnswersBySchemaPropertyAndRecordsRequests() async throws {
        let model = FakeModelChatting()
        model.answer(whenSchemaHas: "screen_kind", #"{"screen_kind":"email"}"#)
        let response = try await model.chat(request(schema: ExtractionSchemaProbe.withProperty("screen_kind")))
        #expect(response.content == #"{"screen_kind":"email"}"#)
        #expect(model.callCount == 1 && model.requests(whereSchemaHas: "screen_kind").count == 1)
        #expect(model.requestJSON(for: request(schema: ExtractionSchemaProbe.withProperty("x"))).contains("[picture]"))
    }

    @Test func theFakeModelCanFail() async {
        let model = FakeModelChatting()
        model.failWith(OllamaClientError.timedOut)
        await #expect(throws: OllamaClientError.self) { try await model.chat(request(schema: ExtractionSchemaProbe.withProperty("a"))) }
    }

    @Test func theFixtureStoresACaptureWithRealPictures() throws {
        let fixture = try makePipelineFixture(); defer { fixture.cleanUp() }
        let provider = StoredPictureProvider(paths: fixture.paths, store: fixture.captures)
        let picture = try #require(try provider.analysisPicture(imageID: fixture.imageID))
        #expect(picture.width == 600 && picture.height == 300)
        #expect(try fixture.captures.count() == 1)
    }
}

enum ExtractionSchemaProbe {
    static func withProperty(_ name: String) -> JSONValue {
        .object(["type": .string("object"), "properties": .object([name: .object(["type": .string("string")])])])
    }
}
