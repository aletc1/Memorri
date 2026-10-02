import Foundation
import Testing
@testable import MemorriCore

/// Memorri writes only in the calendar and the list the user chose, and only entries it made (spec 009 FR-019, ADR 0026).
@Suite struct ScopedEventStoreTests {
    private func scoped(_ fake: FakeEventStore, calendar: String? = "cal-memorri", list: String? = "list-memorri", ours: Set<String> = [], removable: Set<String> = []) -> ScopedEventStore {
        ScopedEventStore(base: fake, calendarID: calendar, listID: list, alsoRemovableFrom: removable, isOurs: { ours.contains($0) })
    }

    @Test func createsOnlyInTheChosenCalendarAndList() throws {
        let fake = FakeEventStore()
        let store = scoped(fake)
        let event = try store.create(.sample(.event), in: "cal-memorri")
        let reminder = try store.create(.sample(.reminder), in: "list-memorri")
        #expect(fake.entries[event]?.containerID == "cal-memorri" && fake.entries[reminder]?.containerID == "list-memorri")
        for other in ["cal-work", "cal-personal"] {
            #expect(throws: SyncError.outsideTarget(other)) { try store.create(.sample(.event), in: other) }
        }
        #expect(throws: SyncError.outsideTarget("list-home")) { try store.create(.sample(.reminder), in: "list-home") }
        #expect(fake.writes.count == 2)                                                  // the refused ones wrote nothing
    }

    @Test func withNoCalendarChosenNoEventIsWrittenAndWithNoListNoReminder() throws {
        let fake = FakeEventStore()
        #expect(throws: SyncError.noTarget(.event)) { try scoped(fake, calendar: nil).create(.sample(.event), in: "cal-memorri") }
        #expect(throws: SyncError.noTarget(.reminder)) { try scoped(fake, list: nil).create(.sample(.reminder), in: "list-memorri") }
        _ = try scoped(fake, calendar: nil).create(.sample(.reminder), in: "list-memorri")       // a reminder still needs only its list
        #expect(fake.writes.count == 1)
    }

    @Test func aTargetThatNoLongerExistsIsRefused() {
        let fake = FakeEventStore()
        fake.calendars.removeAll { $0.id == "cal-memorri" }
        #expect(throws: SyncError.outsideTarget("cal-memorri")) { try scoped(fake).create(.sample(.event), in: "cal-memorri") }
        #expect(fake.writes.isEmpty)
    }

    @Test func neverUpdatesOrDeletesAnEntryMemorriDidNotMake() throws {
        let fake = FakeEventStore()
        let foreign = fake.seedForeign(in: "cal-memorri", title: "Dentist")             // someone else's entry, even inside Memorri's calendar
        let store = scoped(fake, ours: [])
        #expect(throws: SyncError.notOurs(foreign)) { try store.update(id: foreign, .sample(.event)) }
        #expect(throws: SyncError.notOurs(foreign)) { try store.delete(id: foreign, kind: .event) }
        #expect(fake.entries[foreign]?.entry.title == "Dentist" && fake.writes.isEmpty)
    }

    @Test func refusesToWriteToAnEntryTheUserMovedToAnotherCalendar() throws {
        let fake = FakeEventStore()
        let id = try scoped(fake).create(.sample(.event), in: "cal-memorri")
        fake.edit(id) { _ = $0 }                                                         // untouched: still allowed
        try scoped(fake, ours: [id]).update(id: id, .sample(.event, title: "New"))
        fake.clearWrites()
        // The user drags it into Work.
        fake.edit(id) { stored in stored = StoredEntry(id: id, containerID: "cal-work", entry: stored.entry, completed: stored.completed) }
        let store = scoped(fake, ours: [id])
        #expect(throws: SyncError.outsideTarget("cal-work")) { try store.update(id: id, .sample(.event)) }
        #expect(throws: SyncError.outsideTarget("cal-work")) { try store.delete(id: id, kind: .event) }
        #expect(fake.writes.isEmpty)
    }

    @Test func aDeleteOfAnEntryThatIsAlreadyGoneIsQuiet() throws {
        let fake = FakeEventStore()
        try scoped(fake, ours: ["E9"]).delete(id: "E9", kind: .event)
        #expect(fake.writes.isEmpty)
    }

    @Test func anEarlierCalendarCanBeEmptiedOnlyWhenAMoveWasConfirmed() throws {
        let fake = FakeEventStore()
        let old = try ScopedEventStore(base: fake, calendarID: "cal-work", listID: nil, isOurs: { _ in true }).create(.sample(.event), in: "cal-work")
        // Choosing "Memorri" now: without the confirmation the old entry cannot be deleted, and with it nothing can be written to the old one.
        #expect(throws: SyncError.outsideTarget("cal-work")) { try scoped(fake, ours: [old]).delete(id: old, kind: .event) }
        let confirmed = scoped(fake, ours: [old], removable: ["cal-work"])
        try confirmed.delete(id: old, kind: .event)
        #expect(fake.entries[old] == nil)
        #expect(throws: SyncError.outsideTarget("cal-work")) { try confirmed.create(.sample(.event), in: "cal-work") }
    }
}
