import Foundation
import Testing
@testable import MemorriCore

@Suite struct SyncTargetsTests {
    private let calendars = [SyncContainer(id: "a", name: "Personal", account: "iCloud", kind: .event, holdsOtherEntries: true),
                             SyncContainer(id: "b", name: " memorri ", account: "iCloud", kind: .event),
                             SyncContainer(id: "c", name: "Work", account: "Exchange", kind: .event, holdsOtherEntries: true)]

    @Test func aCalendarNamedMemorriIsPreselectedWhateverItsCaseAndNothingElseEver() {
        #expect(SyncTargets.preselect(calendars) == "b")
        #expect(SyncTargets.preselect(Array(calendars.filter { $0.id != "b" })) == nil)
        #expect(SyncTargets.preselect([]) == nil)
    }

    @Test func eachChoiceShowsItsAccountAndANonEmptyOneGetsANotice() {
        #expect(SyncTargets.label(calendars[0]) == "Personal · iCloud")
        #expect(SyncTargets.label(SyncContainer(id: "x", name: "Solo", account: "", kind: .event)) == "Solo")
        #expect(SyncTargets.notice(for: calendars[1]) == nil)
        let notice = SyncTargets.notice(for: calendars[0])
        #expect(notice?.contains("never changes entries it did not make") == true && notice?.contains("calendar of its own") == true)
        #expect(SyncTargets.notice(for: SyncContainer(id: "l", name: "Home", account: "iCloud", kind: .reminder, holdsOtherEntries: true))?.contains("list of its own") == true)
    }

    @Test func aSavedChoiceThatNoLongerExistsIsNotAvailable() {
        #expect(SyncTargets.isStillAvailable("a", in: calendars) && !SyncTargets.isStillAvailable("gone", in: calendars) && !SyncTargets.isStillAvailable(nil, in: calendars))
    }
}
