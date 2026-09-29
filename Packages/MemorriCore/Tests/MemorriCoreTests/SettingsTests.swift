import Testing
@testable import MemorriCore

@Suite struct SettingsTests {
    @Test func feedbackTogglesDefaultToOn() {
        let settings = CaptureFeedbackSettings(store: FakeSettingsStore())
        #expect(settings.flashIcon == true)
        #expect(settings.playSound == true)
    }

    @Test func changesAreReadBack() {
        let settings = CaptureFeedbackSettings(store: FakeSettingsStore())
        settings.flashIcon = false
        settings.playSound = false
        #expect(settings.flashIcon == false)
        #expect(settings.playSound == false)
        settings.flashIcon = true
        #expect(settings.flashIcon == true)
        #expect(settings.playSound == false)
    }

    @Test func usesTheAgreedKeys() {
        let store = FakeSettingsStore()
        let settings = CaptureFeedbackSettings(store: store)
        settings.flashIcon = false
        settings.playSound = false
        #expect(store.rawValue(forKey: "memorri.feedback.flashIcon") == false)
        #expect(store.rawValue(forKey: "memorri.feedback.playSound") == false)
    }
}
