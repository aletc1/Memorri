import Foundation
import Testing
@testable import MemorriCore

@Suite struct ReviewRulesTests {
    private func item(confidence: Double = 0.9, status: ItemStatus = .active) -> Item {
        var item = Item.sample()
        item.confidence = confidence
        item.status = status
        item.end = Date(timeIntervalSince1970: 1_791_964_800)
        return item
    }

    private func reasons(_ item: Item, sources: [ItemField: ObservationSource] = [:], locked: Set<ItemField> = [], duplicate: Bool = false,
                         approved: [ItemField: JSONValue]? = nil, current: [ItemField: JSONValue]? = nil) -> [ReviewReason] {
        ReviewRules.reasons(item: item, chosenSources: sources, locked: locked, hasOpenPossibleDuplicate: duplicate,
                            approvedValues: approved, currentValues: current ?? ReviewRules.snapshot(of: item))
    }

    @Test func theLevelIsFixedAtThreeQuarters() { #expect(ReviewRules.level == 0.75) }

    @Test(arguments: [(0.74, true), (0.75, false), (0.9, false), (0.0, true)])
    func confidenceBelowTheLevelNeedsReview(confidence: Double, flagged: Bool) {
        #expect(reasons(item(confidence: confidence)).contains(.lowConfidence) == flagged)
    }

    @Test(arguments: [(ItemField.start, ReviewReason.guessedStart), (.end, .guessedEnd), (.due, .guessedDue)])
    func aGuessedTimeNeedsReviewUnlessLockedOrRead(field: ItemField, reason: ReviewReason) {
        #expect(reasons(item(), sources: [field: .inferred]) == [reason])
        #expect(reasons(item(), sources: [field: .inferred], locked: [field]).isEmpty)
        #expect(reasons(item(), sources: [field: .read]).isEmpty)
        #expect(reasons(item(), sources: [field: .user]).isEmpty)
        #expect(reasons(item(), sources: [.notes: .inferred]).isEmpty)
    }

    @Test func anOpenPossibleDuplicateNeedsReview() {
        #expect(reasons(item(), duplicate: true) == [.possibleDuplicate])
        #expect(reasons(item(), duplicate: false).isEmpty)
    }

    @Test func reasonsComeInAFixedOrder() {
        let all = reasons(item(confidence: 0.5), sources: [.due: .inferred, .end: .inferred, .start: .inferred], duplicate: true)
        #expect(all == [.lowConfidence, .guessedStart, .guessedEnd, .guessedDue, .possibleDuplicate])
        #expect(all == all.sorted { ReviewReason.allCases.firstIndex(of: $0)! < ReviewReason.allCases.firstIndex(of: $1)! })
    }

    @Test(arguments: ItemField.allCases.filter { ReviewRules.approvedFields.contains($0) })
    func aChangeToAnApprovedFieldNeedsReviewAndEqualValuesDoNot(field: ItemField) {
        let base = item()
        let approved = ReviewRules.snapshot(of: base)
        #expect(reasons(base, approved: approved).isEmpty)
        var current = approved
        current[field] = field == .allDay ? .bool(true) : (field == .title ? .string("Another title") : .date(Date(timeIntervalSince1970: 1_791_999_999)))
        #expect(reasons(base, approved: approved, current: current) == [.changedAfterApproval])
    }

    @Test func missingAndNullValuesAreTheSameWhenComparing() {
        let base = item()
        var approved = ReviewRules.snapshot(of: base)
        approved[.due] = nil
        var current = ReviewRules.snapshot(of: base)
        current[.due] = .null
        #expect(reasons(base, approved: approved, current: current).isEmpty)
    }

    @Test func anApprovalCoversTheDoubtsThatWereThere() {
        let doubtful = item(confidence: 0.3)
        let approved = ReviewRules.snapshot(of: doubtful)
        #expect(reasons(doubtful, sources: [.end: .inferred], duplicate: true, approved: approved).isEmpty)
    }

    @Test(arguments: [ItemStatus.dismissed, .merged])
    func dismissedAndMergedItemsNeverNeedReview(status: ItemStatus) {
        #expect(reasons(item(confidence: 0.1, status: status), sources: [.end: .inferred], duplicate: true).isEmpty)
    }

    @Test func aSnapshotSurvivesItsStoredForm() {
        let snapshot = ReviewRules.snapshot(of: item())
        #expect(ReviewRules.decode(ReviewRules.encode(snapshot)) == snapshot)
        #expect(ReviewRules.decode(nil) == nil)
        #expect(ReviewRules.decode("not json") == nil)
    }

    // MARK: Possibly cancelled (spec 010)

    private let seen = Date(timeIntervalSince1970: 1_800_000_000)
    private func absence(_ event: String, after hours: Double) -> CancelAbsence { CancelAbsence(eventID: event, capturedAt: seen.addingTimeInterval(hours * 3600)) }
    private func cancelled(_ item: Item, absences: [CancelAbsence], last: Date? = nil, cleared: Date? = nil, approved: [ItemField: JSONValue]? = nil) -> [ReviewReason] {
        ReviewRules.reasons(item: item, chosenSources: [:], locked: [], hasOpenPossibleDuplicate: false, approvedValues: approved,
                            currentValues: ReviewRules.snapshot(of: item), absences: absences, lastSighting: last ?? seen, clearedAt: cleared)
    }

    @Test func twoAbsencesFromDifferentCapturesAfterTheLastSightingFlagTheItem() {
        #expect(cancelled(item(), absences: [absence("e1", after: 5), absence("e2", after: 30)]) == [.possiblyCancelled])
        #expect(cancelled(item(), absences: [absence("e1", after: 5)]).isEmpty)                                       // one is not enough
        #expect(cancelled(item(), absences: [absence("e1", after: 5), absence("e1", after: 6)]).isEmpty)              // two displays of one capture are one
        #expect(cancelled(item(), absences: [absence("e1", after: -2), absence("e2", after: 30)]).isEmpty)           // one was before the last sighting
        #expect(cancelled(item(), absences: []).isEmpty)
    }

    @Test func aSightingAfterTheAbsencesClearsTheCount() {
        let absences = [absence("e1", after: 5), absence("e2", after: 30)]
        #expect(cancelled(item(), absences: absences, last: seen.addingTimeInterval(40 * 3600)).isEmpty)
        #expect(ReviewRules.isPossiblyCancelled(absences: absences, lastSighting: nil, clearedAt: nil) == false)       // never seen: nothing to be absent from
    }

    @Test func stillHappeningStopsTheFlagUntilTheItemIsSeenAgain() {
        let absences = [absence("e1", after: 5), absence("e2", after: 30)]
        let decided = seen.addingTimeInterval(50 * 3600)
        #expect(cancelled(item(), absences: absences, cleared: decided).isEmpty)                                          // not seen since the decision
        let later = [absence("e3", after: 80), absence("e4", after: 90)]
        #expect(cancelled(item(), absences: later, last: seen.addingTimeInterval(60 * 3600), cleared: decided) == [.possiblyCancelled])   // seen again, then missing twice
    }

    @Test func aSuspicionAppliesToApprovedItemsToo() {
        let approved = ReviewRules.snapshot(of: item())
        let absences = [absence("e1", after: 5), absence("e2", after: 30)]
        #expect(cancelled(item(), absences: absences, approved: approved) == [.possiblyCancelled])
        var changed = item(); changed.title = "New title"
        #expect(cancelled(changed, absences: absences, approved: approved) == [.changedAfterApproval, .possiblyCancelled])
        #expect(cancelled(item(status: .dismissed), absences: absences).isEmpty)                                        // dismissed items are never flagged
        #expect(ReviewReason.allCases.last == .possiblyCancelled)
    }
}
