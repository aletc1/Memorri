import Testing
@testable import MemorriCore

@Suite struct StorageSettingsTests {
    @Test func defaults() {
        let settings = StorageSettings(store: FakeSettingsStore())
        #expect(settings.modelLongEdge == 2048)
        #expect(settings.retention == .days(7))
    }

    @Test func modelLongEdgeAcceptsTheRangeEnds() {
        let settings = StorageSettings(store: FakeSettingsStore())
        #expect(settings.setModelLongEdge(512))
        #expect(settings.modelLongEdge == 512)
        #expect(settings.setModelLongEdge(4096))
        #expect(settings.modelLongEdge == 4096)
    }

    @Test func modelLongEdgeRejectsOutOfRangeAndKeepsThePreviousValue() {
        let settings = StorageSettings(store: FakeSettingsStore())
        #expect(settings.setModelLongEdge(1024))
        #expect(!settings.setModelLongEdge(511))
        #expect(settings.modelLongEdge == 1024)
        #expect(!settings.setModelLongEdge(4097))
        #expect(settings.modelLongEdge == 1024)
    }

    @Test func retentionAcceptsForeverAndDaysInRange() {
        let settings = StorageSettings(store: FakeSettingsStore())
        #expect(settings.setRetention(.forever))
        #expect(settings.retention == .forever)
        #expect(settings.setRetention(.days(1)))
        #expect(settings.retention == .days(1))
        #expect(settings.setRetention(.days(3650)))
        #expect(settings.retention == .days(3650))
    }

    @Test func retentionRejectsOutOfRangeAndKeepsThePreviousValue() {
        let settings = StorageSettings(store: FakeSettingsStore())
        #expect(settings.setRetention(.days(30)))
        #expect(!settings.setRetention(.days(0)))
        #expect(settings.retention == .days(30))
        #expect(!settings.setRetention(.days(3651)))
        #expect(settings.retention == .days(30))
    }

    @Test func usesTheAgreedKeysAndFormats() {
        let store = FakeSettingsStore()
        let settings = StorageSettings(store: store)
        _ = settings.setModelLongEdge(1536)
        _ = settings.setRetention(.days(14))
        #expect(store.int(forKey: "memorri.storage.modelLongEdge") == 1536)
        #expect(store.string(forKey: "memorri.storage.retention") == "14")
        _ = settings.setRetention(.forever)
        #expect(store.string(forKey: "memorri.storage.retention") == "forever")
    }

    @Test func aStoredValueOutsideTheRangeFallsBackToTheDefault() {
        let store = FakeSettingsStore()
        store.setInt(99, forKey: "memorri.storage.modelLongEdge")
        store.setString("0", forKey: "memorri.storage.retention")
        let settings = StorageSettings(store: store)
        #expect(settings.modelLongEdge == 2048)
        #expect(settings.retention == .days(7))
    }
}
