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
}
