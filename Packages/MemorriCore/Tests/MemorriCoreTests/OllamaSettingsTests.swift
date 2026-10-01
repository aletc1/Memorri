import Testing
@testable import MemorriCore

@Suite struct OllamaSettingsTests {
    private func make() -> (OllamaSettings, FakeSettingsStore) {
        let store = FakeSettingsStore()
        return (OllamaSettings(store: store), store)
    }

    @Test func defaultsComeFromTheSpike() {
        let (settings, _) = make()
        #expect(settings.address == .standard)
        #expect(settings.address.text == "http://localhost:11434")
        #expect(settings.model == nil)
        #expect(settings.think == .off)
        #expect(settings.timeoutSeconds == 300)
        #expect(settings.analysisPaused == false)
        #expect(OllamaSettings.recommendedModel == "qwen3-vl:8b-instruct")
    }

    @Test func aLocalAddressIsAcceptedAndStoredCleanly() {
        let (settings, store) = make()
        #expect(settings.setAddress(" http://127.0.0.1:8080/ "))
        #expect(settings.address.text == "http://127.0.0.1:8080")
        #expect(store.string(forKey: "memorri.ollama.address") == "http://127.0.0.1:8080")
    }

    @Test(arguments: ["http://example.com", "http://192.168.1.5:11434", "http://localhost.evil.com", "", "ftp://localhost"])
    func aNonLocalAddressIsRejectedAndThePreviousOneKept(text: String) {
        let (settings, _) = make()
        #expect(settings.setAddress("http://127.0.0.1:9000"))
        #expect(!settings.setAddress(text))
        #expect(settings.address.text == "http://127.0.0.1:9000")
    }

    @Test func aStoredNonLocalAddressFallsBackToTheStandardOne() {
        let (settings, store) = make()
        store.setString("http://evil.example.com", forKey: "memorri.ollama.address")
        #expect(settings.address == .standard)
    }

    @Test func timeoutAcceptsTheRangeEndsAndRejectsOutsideIt() {
        let (settings, _) = make()
        #expect(settings.setTimeoutSeconds(10) && settings.timeoutSeconds == 10)
        #expect(settings.setTimeoutSeconds(1800) && settings.timeoutSeconds == 1800)
        #expect(!settings.setTimeoutSeconds(9) && settings.timeoutSeconds == 1800)
        #expect(!settings.setTimeoutSeconds(1801) && settings.timeoutSeconds == 1800)
        #expect(OllamaSettings.timeoutRange == 10...1800)
    }

    @Test func aStoredOutOfRangeTimeoutFallsBackToTheDefault() {
        let (settings, store) = make()
        store.setInt(5, forKey: "memorri.ollama.timeoutSeconds")
        #expect(settings.timeoutSeconds == 300)
    }

    @Test func modelThinkAndPausedRoundTrip() {
        let (settings, _) = make()
        settings.setModel("qwen3.8:27b-mlx")
        #expect(settings.model == "qwen3.8:27b-mlx")
        settings.setModel(nil)
        #expect(settings.model == nil)
        for level in ThinkSetting.allCases {
            settings.setThink(level)
            #expect(settings.think == level)
        }
        settings.setAnalysisPaused(true)
        #expect(settings.analysisPaused)
        settings.setAnalysisPaused(false)
        #expect(!settings.analysisPaused)
    }

    @Test func aStoredUnknownThinkValueFallsBackToOff() {
        let (settings, store) = make()
        store.setString("extreme", forKey: "memorri.ollama.think")
        #expect(settings.think == .off)
    }

    @Test func usesTheAgreedKeysAndFormats() {
        let (settings, store) = make()
        settings.setModel("m:1")
        settings.setThink(.high)
        _ = settings.setTimeoutSeconds(120)
        settings.setAnalysisPaused(true)
        #expect(store.string(forKey: "memorri.ollama.model") == "m:1")
        #expect(store.string(forKey: "memorri.ollama.think") == "high")
        #expect(store.int(forKey: "memorri.ollama.timeoutSeconds") == 120)
        #expect(store.bool(forKey: "memorri.analysis.paused", default: false))
    }

    // MARK: matching models (spec 005)

    @Test func matchingModelsDefaultToTheKnownNamesWhenTheyAreInstalled() {
        let (settings, _) = make()
        let both: Set<String> = [OllamaSettings.defaultEmbeddingModel, OllamaSettings.defaultRerankerModel, "other:1"]
        #expect(settings.embeddingModel(installed: both) == "jeffh/intfloat-multilingual-e5-large-instruct:f32")
        #expect(settings.rerankerModel(installed: both) == "fanyx/Qwen3-Reranker-0.6B-Q8_0:latest")
        #expect(settings.embeddingModel(installed: ["other:1"]) == nil)
        #expect(settings.rerankerModel(installed: []) == nil)
    }

    @Test func aChosenMatchingModelIsKeptAndNoneStaysNone() {
        let (settings, _) = make()
        settings.setEmbeddingModel("my-embedder:1")
        settings.setRerankerModel(nil)
        #expect(settings.embeddingModel(installed: ["my-embedder:1", OllamaSettings.defaultEmbeddingModel]) == "my-embedder:1")
        #expect(settings.rerankerModel(installed: [OllamaSettings.defaultRerankerModel]) == nil)
        #expect(settings.embeddingChoice == .named("my-embedder:1"))
        #expect(settings.rerankerChoice == .none)
        settings.setEmbeddingModel(nil)
        #expect(settings.embeddingModel(installed: [OllamaSettings.defaultEmbeddingModel]) == nil)
    }

    @Test func aChoiceNotInstalledGivesNoModel() {
        let (settings, _) = make()
        settings.setRerankerModel("gone:1")
        #expect(settings.rerankerModel(installed: ["x"]) == nil)
        #expect(settings.rerankerChoice == .named("gone:1"))
    }

    @Test func untouchedChoicesAreUnset() {
        let (settings, _) = make()
        #expect(settings.embeddingChoice == .unset && settings.rerankerChoice == .unset)
    }
}
