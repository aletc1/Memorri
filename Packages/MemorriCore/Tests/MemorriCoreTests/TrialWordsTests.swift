import Foundation
import Testing
@testable import MemorriCore

@Suite struct TrialWordsTests {
    private func difference(_ kind: TrialDifference.Kind, state: TrialDifference.State = .open, protection: ProtectionReason? = nil) -> TrialDifference {
        TrialDifference(id: "d", kind: kind, imageID: "i", itemID: nil, findingID: nil, title: "T", changes: [], protection: protection, state: state, confidence: nil, needsReview: false)
    }

    @Test func kindsAndProtectionsAreInWords() {
        #expect(TrialWords.kind(difference(.new)) == "New" && TrialWords.kind(difference(.changed)) == "Changed")
        #expect(TrialWords.kind(difference(.notFound)) == "Not found in this trial" && TrialWords.kind(difference(.unchanged, state: .applied)) == "Applied")
        #expect(TrialWords.protection(.locked([.end, .place])) == "You set end, place" && TrialWords.protection(.approved) == "You approved this item")
        #expect(TrialWords.protection(.dismissed) == "You dismissed this item")
    }

    @Test func onlyOpenUnprotectedNewOrChangedDifferencesCanBeApplied() {
        #expect(difference(.new).applicable && difference(.changed).applicable)
        #expect(!difference(.changed, protection: .approved).applicable && !difference(.new, state: .applied).applicable)
        #expect(!difference(.unchanged).applicable && !difference(.notFound).applicable)
    }

    @Test func progressTotalsAndTheOutOfDateCountAreInWords() {
        let trial = TrialRecord(id: "t", model: "m", promptVersion: "p", think: "off", state: .running, createdAt: Date(), finishedAt: nil,
                                counts: TrialCounts(waiting: 2, read: 3, skipped: 1, failed: 1))
        #expect(TrialWords.progress(trial) == "3 of 7 read, 1 skipped, 1 failed" && TrialWords.state(trial) == "Reading")
        #expect(TrialWords.totals(TrialTotals(new: 1, changed: 2, unchanged: 3, notFound: 4, protected: 1, review: 1, applied: 0)) == "1 new · 2 changed · 4 not found · 3 unchanged · 1 protected · 1 would need review")
        #expect(TrialWords.outOfDate(0) == "Everything was read with the current model and prompt." && TrialWords.outOfDate(1) == "1 capture was read with another model or prompt.")
        #expect(TrialWords.change(FieldChange(field: .end, current: "a", proposed: "b")) == "end: a → b")
    }
}
