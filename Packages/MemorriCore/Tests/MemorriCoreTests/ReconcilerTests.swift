import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ReconcilerTests {
    private let later = Date(timeIntervalSince1970: 1_800_000_000)      // the capture time of the fixture's own picture

    private func reconciler(_ fixture: ReconcileFixture, judge: any MeaningJudging = NoMeaningJudge(),
                            thresholds: ReconcileThresholds = .default) -> Reconciler {
        Reconciler(database: fixture.database, judge: judge, thresholds: thresholds, now: { Date(timeIntervalSince1970: 1_791_999_000) })
    }

    /// Stores `findings` as the analysis of a new picture and reconciles it.
    @discardableResult
    private func see(_ fixture: ReconcileFixture, _ findings: [Finding], context: String? = nil, with r: Reconciler, picture: String? = nil,
                     at date: Date? = nil) async throws -> (imageID: String, summary: ReconcileSummary) {
        let id = try picture ?? fixture.addPicture(at: date ?? later.addingTimeInterval(Double(fixture.imageIDs.count) * 3600))
        try fixture.save(findings, imageID: id, contextID: context)
        return (id, await r.reconcile(imageID: id))
    }

    private func items(_ fixture: ReconcileFixture) throws -> [Item] {
        try ItemStore(database: fixture.database).items(status: [.active, .dismissed, .merged], kinds: nil, contextID: nil).map(\.item)
    }

    private func sightingCount(_ fixture: ReconcileFixture, item: String) throws -> Int {
        try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sightings WHERE item_id = ?", arguments: [item]) ?? 0 }
    }

    // MARK: scenario 1 to 5

    @Test func theSameMeetingSeenTwiceIsOneItemWithTwoSightings() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        let first = try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Daily standup")], with: r)
        let all = try items(fixture)
        #expect(all.count == 1)
        #expect(try sightingCount(fixture, item: all[0].id) == 2)
        #expect(first.summary.created == 1 && first.summary.merged == 0)
        #expect(second.summary.created == 0 && second.summary.merged == 1 && second.summary.error == nil)
        // The summary names the items it created (the notice of new items counts them), and none when it only joined.
        #expect(first.summary.createdItemIDs == [all[0].id] && second.summary.createdItemIDs.isEmpty)
    }

    @Test func aTruncatedTitleJoinsTheItemWithTheFullTitle() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Quarterly planning with the customer")], with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Quarterly planning with the cust…")], with: r)
        let all = try items(fixture)
        #expect(all.count == 1 && all[0].title == "Quarterly planning with the customer")
    }

    @Test func twoDifferentMeetingsAtTheSameTimeStayTwoItemsWhenTheJudgeSaysNo() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 0.1)
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Design review")], with: r, picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Budget review")], with: r)
        #expect(try items(fixture).count == 2)
        #expect(judge.judgeCalls.count == 1 && second.summary.judged == 1 && second.summary.created == 1)
    }

    @Test func theSameTitleOnDifferentDaysIsTwoItems() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        for day in 1...4 {
            try await see(fixture, [fixture.finding("Daily standup", start: ReconcileFixture.minutes(day * 24 * 60))], with: r)
        }
        #expect(try items(fixture).count == 5)
    }

    @Test func theSameTitleAndTimeInTwoContextsIsTwoItems() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("c1", "Customer A"); try fixture.addContext("c2", "Customer B")
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], context: "c1", with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup")], context: "c2", with: r)
        try await see(fixture, [fixture.finding("Daily standup")], context: "c1", with: r)
        let all = try items(fixture)
        #expect(all.count == 2)
        #expect(Set(all.map(\.contextID)) == ["c1", "c2"])
    }

    @Test func aContextOfNilMatchesOnlyNil() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("c1", "Customer A")
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], context: "c1", with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Daily standup")], context: nil, with: r)
        try await see(fixture, [fixture.finding("Daily standup")], context: nil, with: r)
        #expect(try items(fixture).count == 2)
    }

    @Test func aFindingOfAnotherKindFamilyIsNeverMerged() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Send the report")], with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Send the report", start: nil, kind: .task, due: ReconcileFixture.nine)], with: r)
        #expect(try items(fixture).count == 2)
    }

    // MARK: scenario 6, reanalysis

    @Test func analysingThePictureAgainCreatesNoItemsAndKeepsTheirIds() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        let pictureOnly = fixture.finding("Only on this picture", start: ReconcileFixture.minutes(120))
        let (image, _) = try await see(fixture, [fixture.finding("Daily standup"), pictureOnly], with: r, picture: fixture.base.imageID)
        let before = try items(fixture).map(\.id).sorted()
        // The analysis is replaced: the findings get new ids.
        try fixture.save([fixture.finding("Daily standup"), fixture.finding("Only on this picture", start: ReconcileFixture.minutes(120))], imageID: image)
        let again = await r.reconcile(imageID: image)
        #expect(try items(fixture).map(\.id).sorted() == before)
        #expect(again.created == 0 && again.error == nil)
        #expect(try fixture.count("sightings") == 2)
    }

    @Test func aFindingSticksToTheItemOfThisPicturesEarlierSighting() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let (second, _) = try await see(fixture, [fixture.finding("Daily standup")], with: r)
        // Simulate a split: the second picture's sighting now belongs to its own, more recently seen item.
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "split-off"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "UPDATE sightings SET item_id = 'split-off' WHERE image_id = ?", arguments: [second])
            try db.execute(sql: "UPDATE observations SET item_id = 'split-off' WHERE sighting_id IN (SELECT id FROM sightings WHERE image_id = ?)", arguments: [second])
            try db.execute(sql: "UPDATE items SET last_seen = datetime('now', '+1 day') WHERE id = 'split-off'")
        }
        try fixture.save([fixture.finding("Daily standup")], imageID: second)
        _ = await r.reconcile(imageID: second)
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE image_id = ?", arguments: [second]) }
        #expect(owner == "split-off")
        #expect(try items(fixture).count == 2)
    }

    @Test func twoFindingsOfOnePictureThatAreDuplicatesBecomeOneItem() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        let (image, summary) = try await see(fixture, [fixture.finding("Daily standup"), fixture.finding("Daily standup")], with: r,
                                             picture: fixture.base.imageID)
        let all = try items(fixture)
        #expect(all.count == 1 && summary.created == 1 && summary.merged == 1)
        #expect(try sightingCount(fixture, item: all[0].id) == 2)
        _ = image
    }

    @Test func aPictureAnalysedBeforeReconciliationExistedIsNotTouchedUntilAskedFor() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.save([fixture.finding("Daily standup")])
        #expect(try items(fixture).isEmpty)
        let stamp = try fixture.read { try Date.fetchOne($0, sql: "SELECT reconciled_at FROM image_analysis") }
        #expect(stamp == nil)
        let summary = await reconciler(fixture).reconcile(imageID: fixture.base.imageID)
        #expect(summary.created == 1)
        #expect(try items(fixture).count == 1)
        let after = try fixture.read { try Date.fetchOne($0, sql: "SELECT reconciled_at FROM image_analysis") }
        #expect(after == Date(timeIntervalSince1970: 1_791_999_000))
    }

    // MARK: the uncertain band

    @Test func aTranslatedTitleAtTheSameTimeGoesToTheJudgeAndMergesOnYes() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge()
        judge.setAnswer(0.99, "daily standup", "reunion diaria")
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Reunión diaria")], with: r)
        #expect(try items(fixture).count == 1)
        #expect(judge.judgeCalls.count == 1 && second.summary.judged == 1)
        let call = try #require(judge.judgeCalls.first)
        #expect(call.0.title == "Reunión diaria" && call.1.title == "Daily standup")
        #expect(call.0.when.contains("2026") == false)   // a short readable time, not an ISO stamp
    }

    @Test func withoutAJudgeAnUncertainPairBecomesANewItemAndAPossibleDuplicate() async throws {
        for judge in [any MeaningJudging](arrayLiteral: NoMeaningJudge(), FakeMeaningJudge(mode: .throwing), FakeMeaningJudge(mode: .unavailable)) {
            let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
            let r = reconciler(fixture, judge: judge)
            try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
            let second = try await see(fixture, [fixture.finding("Reunión diaria")], with: r)
            let all = try items(fixture)
            #expect(all.count == 2)
            #expect(try fixture.count("possible_duplicates") == 1)
            #expect(second.summary.possibleDuplicates == 1 && second.summary.error == nil)
            let reason = try fixture.read { try String.fetchOne($0, sql: "SELECT decision_json FROM sightings WHERE image_id = ?", arguments: [second.imageID]) }
            #expect(reason?.contains("judge-unavailable") == true)
        }
    }

    @Test func aHighCosineSendsAWeakTitleAtAnotherTimeToTheJudge() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 0.2)
        judge.setVector([1, 0], for: "daily standup"); judge.setVector([0.99, 0.14], for: "reunion diaria")
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Reunión diaria", start: ReconcileFixture.minutes(10))], with: r)
        #expect(judge.judgeCalls.count == 1)
        #expect(try items(fixture).count == 2)
    }

    @Test func aLowCosineLeavesAWeakTitleAtAnotherTimeAsANewItemWithoutAskingTheJudge() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        judge.setVector([1, 0], for: "daily standup"); judge.setVector([0, 1], for: "planning")
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        try await see(fixture, [fixture.finding("Planning", start: ReconcileFixture.minutes(10))], with: r)
        #expect(judge.judgeCalls.isEmpty)
        #expect(try items(fixture).count == 2)
    }

    @Test func twoFindingsOfOnePictureWithOtherTitlesAreNeverJudgedAgainstEachOther() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Sprint review"), fixture.finding("Sprint retrospective")], with: r, picture: fixture.base.imageID)
        #expect(judge.judgeCalls.isEmpty)
        #expect(try items(fixture).count == 2)
        #expect(try fixture.count("possible_duplicates") == 0)
    }

    @Test func aFindingDoesNotJoinAnItemThatAnotherFindingOfItsPictureAlreadyJoined() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Sprint review")], with: r, picture: fixture.base.imageID)
        // the next picture shows the same review and another meeting at the same time: the second one is not the first again
        try await see(fixture, [fixture.finding("Sprint review"), fixture.finding("Sprint retrospective")], with: r)
        #expect(judge.judgeCalls.isEmpty)
        #expect(try items(fixture).count == 2)
        // a later picture that shows only the other title joins the item made for it, by text
        try await see(fixture, [fixture.finding("Sprint retrospective")], with: r)
        #expect(try items(fixture).count == 2)
    }

    @Test func aTruncatedTitleInTheSamePictureStillJoinsByText() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Quarterly planning workshop"), fixture.finding("Quarterly planning work")], with: r, picture: fixture.base.imageID)
        #expect(try items(fixture).count == 1)
    }

    // MARK: undated

    @Test func anAppointmentWithNoResolvedStartIsMatchedLikeAnUndatedTaskAndDoesNotRepeat() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Quarterly review", start: nil)], with: r, picture: fixture.base.imageID)
        for _ in 1...3 { try await see(fixture, [fixture.finding("Quarterly review", start: nil)], with: r) }
        #expect(try items(fixture).count == 1)
        // a dated finding never joins an undated item
        try await see(fixture, [fixture.finding("Quarterly review")], with: r)
        #expect(try items(fixture).count == 2)
    }

    @Test func undatedTitlesInTheUncertainBandAreFlaggedAndNeverSentToTheJudge() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let judge = FakeMeaningJudge(defaultAnswer: 1)
        let r = reconciler(fixture, judge: judge)
        try await see(fixture, [fixture.finding("Send the monthly invoice", start: nil, kind: .task)], with: r, picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Send the monthly report", start: nil, kind: .task)], with: r)
        #expect(judge.judgeCalls.isEmpty)
        #expect(try items(fixture).count == 2)
        #expect(try fixture.count("possible_duplicates") == 1 && second.summary.possibleDuplicates == 1)
    }

    // MARK: stored decision

    @Test func everySightingStoresWhyItWasMadeAndWhatItWas() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let second = try await see(fixture, [fixture.finding("Daily standup")], with: r)
        let json = try fixture.read { try String.fetchOne($0, sql: "SELECT decision_json FROM sightings WHERE image_id = ?", arguments: [second.imageID]) }
        let decision = try #require(json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(decision["rule"] as? String == "text-time")
        #expect((decision["scores"] as? [String: Any])?["text"] as? Double == 1)
        #expect(decision["kind"] as? String == "appointment" && decision["timezone"] as? String == "UTC")
        #expect(decision["candidate"] is String)
    }

    // MARK: apply

    @Test func applyFallsBackToANewItemWhenItsTargetIsGone() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let second = try fixture.addPicture(at: later.addingTimeInterval(7200))
        try fixture.save([fixture.finding("Daily standup")], imageID: second)
        let plan = try await r.plan(imageID: second)
        guard case .existing = plan.steps[0].target else { Issue.record("expected a merge target"); return }
        try fixture.write { try $0.execute(sql: "DELETE FROM items") }
        let summary = try r.apply(plan)
        #expect(summary.created == 1)
        #expect(try items(fixture).count == 1)
    }

    @Test func applyFollowsAMergedItemToItsSurvivor() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        let (first, _) = try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let second = try fixture.addPicture(at: later.addingTimeInterval(7200))
        try fixture.save([fixture.finding("Daily standup")], imageID: second)
        let plan = try await r.plan(imageID: second)
        guard case .existing(let target) = plan.steps[0].target else { Issue.record("expected a merge target"); return }
        try fixture.write { db in
            try ItemStore.insert(db, Item.sample(id: "survivor"), at: Date(timeIntervalSince1970: 1))
            try db.execute(sql: "UPDATE items SET status = 'merged', merged_into = 'survivor' WHERE id = ?", arguments: [target])
            try db.execute(sql: "UPDATE sightings SET item_id = 'survivor' WHERE image_id = ?", arguments: [first])
        }
        _ = try r.apply(plan)
        let owner = try fixture.read { try String.fetchOne($0, sql: "SELECT item_id FROM sightings WHERE image_id = ?", arguments: [second]) }
        #expect(owner == "survivor")
        #expect(try items(fixture).count == 2)       // the merged-away item and the survivor; no third
    }

    @Test func aPictureWithoutAnalysisReportsAnErrorAndChangesNothing() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let summary = await reconciler(fixture).reconcile(imageID: fixture.base.imageID)
        #expect(summary.error != nil && summary.created == 0)
        #expect(try items(fixture).isEmpty)
    }

    @Test func aPictureWithNoFindingsStillCountsAsReconciledAndClearsItsEarlierSightings() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        let (image, _) = try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        try fixture.save([], imageID: image)
        let summary = await r.reconcile(imageID: image)
        #expect(summary.error == nil && summary.created == 0)
        #expect(try fixture.count("sightings") == 0)
        #expect(try items(fixture).isEmpty)          // nothing user-touched, so the empty item goes
        let stamp = try fixture.read { try Date.fetchOne($0, sql: "SELECT reconciled_at FROM image_analysis") }
        #expect(stamp != nil)
    }

    // MARK: what the user did stays (user story 3)

    private func ops(_ fixture: ReconcileFixture) -> ItemOperations {
        ItemOperations(database: fixture.database, now: { Date(timeIntervalSince1970: 1_800_200_000) })
    }

    @Test func aLaterSightingWithTheOldTitleLeavesTheUsersTitleAndAddsAnObservation() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let id = try items(fixture)[0].id
        try ops(fixture).edit(id, field: .title, value: .string("My standup"))
        try await see(fixture, [fixture.finding("Daily standup")], with: r)
        let all = try items(fixture)
        #expect(all.count == 1 && all[0].title == "My standup")
        let titles = try fixture.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE field = 'title'") }
        #expect(titles == 3)         // two read, one the user's
    }

    @Test func aDismissedEventSeenAgainGetsTheSightingAndStaysDismissed() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Quarterly planning with the customer")], with: r, picture: fixture.base.imageID)
        let id = try items(fixture)[0].id
        try ops(fixture).dismiss(id)
        for title in ["Quarterly planning with the customer", "Quarterly planning with the cust…"] {
            let seen = try await see(fixture, [fixture.finding(title)], with: r)
            #expect(seen.summary.created == 0)
        }
        let all = try items(fixture)
        #expect(all.count == 1 && all[0].status == .dismissed)
        #expect(try sightingCount(fixture, item: id) == 3)
    }

    @Test func aClearlyDifferentEventAtTheTimeOfADismissedOneIsANewItem() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture, judge: FakeMeaningJudge(defaultAnswer: 0.05))
        try await see(fixture, [fixture.finding("Design review")], with: r, picture: fixture.base.imageID)
        try ops(fixture).dismiss(try items(fixture)[0].id)
        try await see(fixture, [fixture.finding("Budget review")], with: r)
        let all = try items(fixture)
        #expect(all.count == 2)
        #expect(Set(all.map(\.status)) == [.dismissed, .active])
    }

    @Test func afterARestoreLaterSightingsMergeIntoTheItemWithItsHistory() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let id = try items(fixture)[0].id
        try ops(fixture).dismiss(id)
        try await see(fixture, [fixture.finding("Daily standup")], with: r)
        try ops(fixture).restore(id)
        try await see(fixture, [fixture.finding("Daily standup")], with: r)
        let all = try items(fixture)
        #expect(all.count == 1 && all[0].status == .active && all[0].id == id)
        #expect(try sightingCount(fixture, item: id) == 3)
    }

    @Test func afterAnUnlockTheFieldTakesTheValueTheRulesChoose() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 4")], with: r, picture: fixture.base.imageID)
        let id = try items(fixture)[0].id
        try ops(fixture).edit(id, field: .place, value: .string("Room 9"))
        try await see(fixture, [fixture.finding("Daily standup", place: "Room 7")], with: r)
        #expect(try items(fixture)[0].place == "Room 9")
        try ops(fixture).unlock(id, field: .place)
        #expect(try items(fixture)[0].place == "Room 7")
    }

    @Test func aLockedStartIsNotMovedByALaterSightingAtAnotherTime() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        let r = reconciler(fixture)
        try await see(fixture, [fixture.finding("Daily standup")], with: r, picture: fixture.base.imageID)
        let id = try items(fixture)[0].id
        let mine = ReconcileFixture.minutes(10)
        try ops(fixture).edit(id, field: .start, value: .date(mine))
        let seen = try await see(fixture, [fixture.finding("Daily standup")], with: r)       // the sighting still says 09:00
        #expect(seen.summary.created == 0)
        let all = try items(fixture)
        #expect(all.count == 1 && all[0].start == mine)
        #expect(try sightingCount(fixture, item: id) == 2)
    }
}
