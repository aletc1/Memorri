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
}
