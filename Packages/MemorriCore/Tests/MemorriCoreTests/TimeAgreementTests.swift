import Foundation
import Testing
@testable import MemorriCore

@Suite struct TimeAgreementTests {
    private let nine = ReconcileFixture.nine      // 2026-10-14 07:00 UTC

    private func event(_ minutes: Int, length: Int? = nil, allDay: Bool = false, tz: String = "UTC") -> TimeSpan {
        let start = ReconcileFixture.minutes(minutes, after: nine)
        return TimeSpan(start: start, end: length.map { start.addingTimeInterval(Double($0) * 60) }, allDay: allDay, timezone: tz, family: .event)
    }

    private func todo(_ minutes: Int?, tz: String = "UTC") -> TimeSpan {
        TimeSpan(start: minutes.map { ReconcileFixture.minutes($0, after: nine) }, end: nil, allDay: false, timezone: tz, family: .todo)
    }

    @Test func sameStartIsACandidateWithScoreOne() {
        #expect(TimeAgreement.isCandidate(event(0), event(0)))
        #expect(TimeAgreement.score(event(0), event(0)) == 1)
    }

    @Test func overlappingIntervalsAreCandidatesWithScoreEight() {
        let a = event(0, length: 60), b = event(30, length: 60)
        #expect(TimeAgreement.isCandidate(a, b))
        #expect(TimeAgreement.score(a, b) == 0.8)
    }

    @Test func startsWithinFifteenMinutesAreCandidatesWithScoreSix() {
        #expect(TimeAgreement.isCandidate(event(0, length: 30), event(15)))
        #expect(TimeAgreement.score(event(0, length: 10), event(15)) == 0.6)
        #expect(!TimeAgreement.isCandidate(event(0, length: 10), event(16)))
    }

    @Test func aMeetingOnAnotherDayIsNotACandidate() {
        #expect(!TimeAgreement.isCandidate(event(0), event(24 * 60)))
        #expect(!TimeAgreement.isCandidate(event(0, length: 60), event(24 * 60 + 5, length: 60)))
    }

    @Test func theDayIsTheCalendarDayInTheContextsTimeZone() {
        // 21:50Z and 22:00Z: the same day in UTC, two days in Madrid (23:50 on the 14th, 00:00 on the 15th).
        let late = 14 * 60 + 50, early = 15 * 60
        #expect(TimeAgreement.isCandidate(event(late), event(early)))
        #expect(!TimeAgreement.isCandidate(event(late, tz: "Europe/Madrid"), event(early, tz: "Europe/Madrid")))
    }

    @Test func anAllDaySightingIsACandidateForAnyTimeThatDayWithScoreHalf() {
        let allDay = event(0, allDay: true)
        #expect(TimeAgreement.isCandidate(allDay, event(9 * 60)))
        #expect(TimeAgreement.score(allDay, event(9 * 60)) == 0.5)
        #expect(!TimeAgreement.isCandidate(allDay, event(24 * 60)))
        #expect(TimeAgreement.score(allDay, event(0, allDay: true)) == 1)
    }

    @Test func tasksAreCandidatesWhenDueWithinADayOrBothUndated() {
        #expect(TimeAgreement.isCandidate(todo(0), todo(0)) && TimeAgreement.score(todo(0), todo(0)) == 1)
        #expect(TimeAgreement.isCandidate(todo(0), todo(24 * 60)))
        #expect(!TimeAgreement.isCandidate(todo(0), todo(24 * 60 + 1)))
        #expect(TimeAgreement.isCandidate(todo(nil), todo(nil)) && TimeAgreement.score(todo(nil), todo(nil)) == 1)
        #expect(!TimeAgreement.isCandidate(todo(nil), todo(0)))
        #expect(TimeAgreement.score(todo(0), todo(24 * 60)) == 0.6)
    }

    @Test func anEventWithNoStartIsMatchedLikeAnUndatedTask() {
        let undated = TimeSpan(start: nil, end: nil, allDay: false, timezone: "UTC", family: .event)
        #expect(TimeAgreement.isCandidate(undated, undated) && TimeAgreement.score(undated, undated) == 1)
        #expect(!TimeAgreement.isCandidate(undated, event(0)))
    }

    @Test func differentFamiliesAreNeverCandidates() {
        #expect(!TimeAgreement.isCandidate(event(0), todo(0)))
        #expect(!TimeAgreement.isCandidate(todo(nil), TimeSpan(start: nil, end: nil, allDay: false, timezone: "UTC", family: .event)))
    }

    @Test func dayKeyIsTheCalendarDayInTheTimeZone() {
        #expect(TimeAgreement.dayKey(ReconcileFixture.nine, timezone: "UTC") == "2026-10-14")
        #expect(TimeAgreement.dayKey(ReconcileFixture.minutes(15 * 60 + 10), timezone: "Europe/Madrid") == "2026-10-15")
        #expect(TimeAgreement.dayKey(nil, timezone: "UTC") == nil)
        #expect(TimeAgreement.dayKey(ReconcileFixture.nine, timezone: "Not/AZone") == "2026-10-14")
    }
}
