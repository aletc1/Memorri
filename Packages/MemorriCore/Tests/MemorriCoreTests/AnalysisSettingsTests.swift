import Foundation
import Testing
@testable import MemorriCore

@Suite struct AnalysisSettingsTests {
    @Test func automaticAnalysisIsOnByDefault() {
        #expect(AnalysisSettings(store: FakeSettingsStore()).automatic)
    }

    @Test func theSwitchRoundTripsUnderItsKey() {
        let store = FakeSettingsStore()
        let settings = AnalysisSettings(store: store)
        settings.setAutomatic(false)
        #expect(settings.automatic == false)
        #expect(store.rawValue(forKey: "memorri.analysis.auto") == false)
        #expect(AnalysisSettings(store: store).automatic == false)
        settings.setAutomatic(true)
        #expect(AnalysisSettings(store: store).automatic)
        #expect(AnalysisSettings.autoKey == "memorri.analysis.auto")
    }
}
