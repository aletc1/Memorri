import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ReconcilerFieldTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)      // the capture time of the fixture's own picture

    private func reconciler(_ fixture: ReconcileFixture) -> Reconciler {
        Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_791_999_000) })
    }

    /// Analyses one picture per entry (the first is the fixture's own), the n-th taken n hours after `t0`.
    private func see(_ fixture: ReconcileFixture, _ findings: [[Finding]], context: String? = nil) async throws {
        let r = reconciler(fixture)
        for (n, list) in findings.enumerated() {
            let image = n == 0 ? fixture.base.imageID : try fixture.addPicture(at: t0.addingTimeInterval(Double(n) * 3600))
            try fixture.save(list, imageID: image, contextID: context)
            let summary = await r.reconcile(imageID: image)
            #expect(summary.error == nil)
        }
    }

    private func onlyItem(_ fixture: ReconcileFixture) throws -> Item {
        let all = try ItemStore(database: fixture.database).items(status: [.active, .dismissed], kinds: nil, contextID: nil).map(\.item)
        #expect(all.count == 1)
        return try #require(all.first)
    }

    private func observations(_ fixture: ReconcileFixture, _ field: ItemField) throws -> [Row] {
        try fixture.read { try Row.fetchAll($0, sql: "SELECT * FROM observations WHERE field = ? ORDER BY observed_at", arguments: [field.rawValue]) }
    }

    @Test func aGuessedEndIsReplacedByALaterReadEndAndTheGuessStaysAsHistory() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let guess = ReconcileFixture.minutes(60), real = ReconcileFixture.minutes(30)
        try await see(fixture, [[fixture.finding("Daily standup", end: guess, inferredEnd: true)],
                                [fixture.finding("Daily standup", end: real)]])
        #expect(try onlyItem(fixture).end == real)
        let ends = try observations(fixture, .end)
        #expect(ends.count == 2)
        #expect(Set(ends.map { $0["source"] as String }) == ["inferred", "read"])
    }

    @Test func aGuessedEndSeenAfterARealOneDoesNotReplaceIt() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let real = ReconcileFixture.minutes(30)
        try await see(fixture, [[fixture.finding("Daily standup", end: real)],
                                [fixture.finding("Daily standup", end: ReconcileFixture.minutes(60), inferredEnd: true)]])
        #expect(try onlyItem(fixture).end == real)
    }

    @Test func theFullTitleStaysAndTheTruncatedOneIsAnAlias() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Quarterly planning with the customer", confidence: 0.7)],
                                [fixture.finding("Quarterly planning with the cust…", confidence: 0.75)]])
        let item = try onlyItem(fixture)
        #expect(item.title == "Quarterly planning with the customer")
        let aliases = try fixture.read { try String.fetchAll($0, sql: "SELECT title FROM item_aliases WHERE item_id = ? ORDER BY normalised", arguments: [item.id]) }
        #expect(aliases.contains("Quarterly planning with the cust…") && aliases.contains("Quarterly planning with the customer"))
    }

    @Test func twoSightingsThatDisagreeWithSimilarConfidenceGiveTheMoreRecentValueAndKeepTheOther() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Daily standup", confidence: 0.85, place: "Room 4")],
                                [fixture.finding("Daily standup", confidence: 0.8, place: "Room 7")]])
        #expect(try onlyItem(fixture).place == "Room 7")
        #expect(try observations(fixture, .place).count == 2)
    }

    @Test func aMuchMoreConfidentEarlierValueBeatsALaterWeakOne() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Daily standup", confidence: 0.95, place: "Room 4")],
                                [fixture.finding("Daily standup", confidence: 0.6, place: "Room 7")]])
        #expect(try onlyItem(fixture).place == "Room 4")
    }

    @Test func aPlaceAndPeopleSeenOnlyInTheSecondSightingAppearOnTheItem() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Daily standup")],
                                [fixture.finding("Daily standup", people: ["Anna", "Ben"], place: "Room 4")],
                                [fixture.finding("Daily standup", people: ["Ben", "Carl"])]])
        let item = try onlyItem(fixture)
        #expect(item.place == "Room 4" && item.people == ["Anna", "Ben", "Carl"])
    }

    @Test func anAllDaySightingJoinedByATimedOneGivesTheTimedValue() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let midnight = ReconcileFixture.minutes(-7 * 60)
        try await see(fixture, [[fixture.finding("Workshop", start: midnight, allDay: true, confidence: 0.9)],
                                [fixture.finding("Workshop", start: ReconcileFixture.nine, confidence: 0.7)]])
        let item = try onlyItem(fixture)
        #expect(item.start == ReconcileFixture.nine && !item.allDay)
    }

    @Test func theKindIsTheMostFrequentAndATieGoesToTheLatest() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let due = ReconcileFixture.nine
        func todo(_ kind: FindingKind) -> [Finding] { [fixture.finding("Send the report to Anna", start: nil, kind: kind, due: due)] }
        try await see(fixture, [todo(.task), todo(.reminder)])
        #expect(try onlyItem(fixture).kind == .reminder)
        let more = try fixture.addPicture(at: t0.addingTimeInterval(5 * 3600))
        try fixture.save(todo(.task), imageID: more)
        _ = await reconciler(fixture).reconcile(imageID: more)
        #expect(try onlyItem(fixture).kind == .task)       // two tasks against one reminder
    }

    @Test func theContextIsTheOneOfTheSightingsAndNeverChangesBySightings() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("c1", "Customer A")
        try await see(fixture, [[fixture.finding("Daily standup")], [fixture.finding("Daily standup")]], context: "c1")
        #expect(try onlyItem(fixture).contextID == "c1")
    }

    @Test func confidenceIsTheHighestAndSeenTimesFollowTheCaptures() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Daily standup", confidence: 0.6)], [fixture.finding("Daily standup", confidence: 0.9)],
                                [fixture.finding("Daily standup", confidence: 0.7)]])
        let item = try onlyItem(fixture)
        #expect(item.confidence == 0.9)
        #expect(item.lastSeen == t0.addingTimeInterval(2 * 3600))
        #expect(item.firstSeen == t0)
    }

    @Test func theDayKeyIsTheDayOfTheStartInTheItemsTimeZone() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let lateEvening = ReconcileFixture.minutes(15 * 60 + 30)       // 22:30Z on the 14th is 00:30 on the 15th in Madrid
        try await see(fixture, [[fixture.finding("Night shift handover", start: lateEvening, timezone: "Europe/Madrid")]])
        let item = try onlyItem(fixture)
        #expect(item.timezone == "Europe/Madrid" && item.dayKey == "2026-10-15")
    }

    @Test func aTasksDayKeyFollowsItsDueDate() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Send the report", start: nil, kind: .task, due: ReconcileFixture.nine)]])
        #expect(try onlyItem(fixture).dayKey == "2026-10-14")
        try await see(fixture, [[fixture.finding("Call the bank", start: nil, kind: .task)]])
        let undated = try ItemStore(database: fixture.database).items(status: [.active], kinds: nil, contextID: nil).map(\.item).first { $0.title == "Call the bank" }
        #expect(undated?.dayKey == nil)
    }

    @Test func everyFieldShownIsStoredAsAnObservationWithItsSource() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try await see(fixture, [[fixture.finding("Daily standup", end: ReconcileFixture.minutes(30), inferredEnd: true, people: ["Anna"], place: "Room 4")]])
        let fields = try fixture.read { try Row.fetchAll($0, sql: "SELECT field, source FROM observations ORDER BY field") }
        let bySource = Dictionary(uniqueKeysWithValues: fields.map { ($0["field"] as String, $0["source"] as String) })
        #expect(Set(bySource.keys) == ["all_day", "end", "people", "place", "start", "title"])
        #expect(bySource["end"] == "inferred" && bySource["start"] == "read" && bySource["title"] == "read")
    }
}
