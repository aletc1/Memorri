import Foundation
import Testing
@testable import MemorriCore

@Suite struct ItemTypesTests {
    @Test func kindsMapToFamilies() {
        #expect(KindFamily(kind: .appointment) == .event)
        for kind in [FindingKind.task, .reminder, .deadline] { #expect(KindFamily(kind: kind) == .todo) }
    }

    @Test func fieldRawValuesMatchTheObservationsColumn() {
        #expect(ItemField.allCases.map(\.rawValue) == ["title", "start", "end", "all_day", "due", "remind", "people", "place", "notes"])
        #expect(ItemField(rawValue: "all_day") == .allDay)
    }

    @Test func statusAndSourceRawValuesMatchTheColumns() {
        #expect(ItemStatus(rawValue: "merged") == .merged && ItemStatus(rawValue: "dismissed") == .dismissed && ItemStatus(rawValue: "active") == .active)
        #expect(ObservationSource(rawValue: "user") == .user && ObservationSource(rawValue: "inferred") == .inferred && ObservationSource(rawValue: "read") == .read)
    }

    @Test func dateValuesRoundTripThroughJSONAsUTCStrings() {
        let date = Date(timeIntervalSince1970: 1_791_961_200)
        let value = JSONValue.date(date)
        #expect(value == .string("2026-10-14T07:00:00Z"))
        #expect(value.asDate == date)
        #expect(JSONValue.null.asDate == nil)
        #expect(JSONValue.string("not a date").asDate == nil)
        #expect(JSONValue.date(nil) == .null)
    }

    @Test func itemFamilyFollowsItsKind() {
        var item = Item.sample(kind: .task)
        #expect(item.family == .todo)
        item.kind = .appointment
        #expect(item.family == .event)
    }
}
