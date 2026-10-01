import Foundation
import GRDB
import Testing
@testable import MemorriCore

@Suite struct ItemListModelTests {
    private func row(_ item: Item, sightings: Int = 1, locked: Bool = false, possible: Bool = false) -> ItemRow {
        ItemRow(item: item, sightingCount: sightings, locked: locked, possibleDuplicate: possible)
    }

    private func item(_ title: String, kind: FindingKind = .appointment, start: Date? = ReconcileFixture.nine, due: Date? = nil, status: ItemStatus = .active,
                      context: String? = nil, timezone: String = "UTC", allDay: Bool = false) -> Item {
        var made = Item.sample(kind: kind, title: title, start: kind == .appointment ? start : nil, contextID: context)
        made.due = due; made.status = status; made.timezone = timezone; made.allDay = allDay
        return made
    }

    // MARK: filters and order

    @Test func filtersByKindFamilyContextAndDismissed() {
        let rows = [row(item("Standup")), row(item("Pay rent", kind: .task, start: nil, due: ReconcileFixture.nine, context: "a")),
                    row(item("Old", status: .dismissed, context: "a")), row(item("Call", kind: .reminder, start: nil, context: "b"))]
        func titles(_ filter: ItemFilter) -> [String] { ItemListModel.visible(rows, filter: filter).map(\.item.title) }
        #expect(titles(ItemFilter()) == ["Pay rent", "Standup", "Call"])
        #expect(titles(ItemFilter(showDismissed: true)).contains("Old"))
        #expect(Set(titles(ItemFilter(kind: .appointments))) == ["Standup"])
        #expect(Set(titles(ItemFilter(kind: .tasks))) == ["Pay rent", "Call"])
        #expect(titles(ItemFilter(context: .context("a"))) == ["Pay rent"])
        #expect(titles(ItemFilter(context: .none)) == ["Standup"])
        #expect(Set(titles(ItemFilter(kind: .tasks, context: .context("b")))) == ["Call"])
    }

    @Test func sortsByStartOrDueThenTitleWithUndatedLast() {
        let t = ReconcileFixture.nine
        let rows = [row(item("Zeta", start: t)), row(item("Alpha", start: t)), row(item("Undated", kind: .task, start: nil)),
                    row(item("Early", start: t.addingTimeInterval(-3600))), row(item("Due later", kind: .task, start: nil, due: t.addingTimeInterval(7200)))]
        #expect(ItemListModel.visible(rows.reversed(), filter: ItemFilter()).map(\.item.title) == ["Early", "Alpha", "Zeta", "Due later", "Undated"])
    }

    @Test func filterStatusesAndFamilies() {
        #expect(ItemFilter().statuses == [.active])
        #expect(ItemFilter(showDismissed: true).statuses == [.active, .dismissed])
        #expect(ItemFilter().families == nil && ItemFilter(kind: .appointments).families == [.event] && ItemFilter(kind: .tasks).families == [.todo])
    }

    // MARK: row text

    @Test func dateTextIsInTheItemsOwnZone() {
        let start = Date(timeIntervalSince1970: 1_791_961_200)      // Wed 14 Oct 2026 07:00 UTC
        #expect(ItemListModel.dateText(item("A", start: start, timezone: "UTC")) == "Wed 14 Oct 07:00")
        #expect(ItemListModel.dateText(item("A", start: start, timezone: "Europe/Madrid")) == "Wed 14 Oct 09:00")
        #expect(ItemListModel.dateText(item("A", start: start, timezone: "America/New_York")) == "Wed 14 Oct 03:00")
    }

    @Test func dateTextForAllDayDueAndUndated() {
        let day = Date(timeIntervalSince1970: 1_791_936_000)        // Wed 14 Oct 2026 00:00 UTC
        #expect(ItemListModel.dateText(item("A", start: day, allDay: true)) == "Wed 14 Oct, all day")
        #expect(ItemListModel.dateText(item("T", kind: .task, start: nil, due: ReconcileFixture.nine)) == "Due Wed 14 Oct 07:00")
        #expect(ItemListModel.dateText(item("T", kind: .task, start: nil)) == "No date")
        #expect(ItemListModel.dateText(item("A", start: nil)) == "No date")
    }

    @Test func rowTextHasSightingsBadgesAndDimming() {
        let plain = ItemListModel.rowText(row(item("Standup")), contextName: "Customer A")
        #expect(plain.title == "Standup" && plain.sightings == "1 sighting" && plain.context == "Customer A")
        #expect(plain.possibleDuplicate == false && plain.locked == false && plain.dimmed == false)
        let busy = ItemListModel.rowText(row(item("Old", status: .dismissed), sightings: 3, locked: true, possible: true), contextName: nil)
        #expect(busy.sightings == "3 sightings" && busy.context == "No context")
        #expect(busy.possibleDuplicate && busy.locked && busy.dimmed)
    }

    // MARK: actions

    @Test func mergeNeedsExactlyTwoLiveItems() {
        let a = row(item("A")), b = row(item("B")), c = row(item("C")), gone = row(item("Gone", status: .merged))
        #expect(ItemListModel.canMerge([a, b]))
        #expect(ItemListModel.canMerge([a]) == false && ItemListModel.canMerge([a, b, c]) == false && ItemListModel.canMerge([]) == false)
        #expect(ItemListModel.canMerge([a, gone]) == false)
        #expect(ItemListModel.canMerge([a, row(item("D", status: .dismissed))]))
    }

    @Test func dismissOrRestoreFollowsTheSelection() {
        let active = row(item("A")), dismissed = row(item("B", status: .dismissed))
        #expect(ItemListModel.statusAction(for: [active, row(item("C"))]) == .dismiss)
        #expect(ItemListModel.statusAction(for: [dismissed]) == .restore)
        #expect(ItemListModel.statusAction(for: [active, dismissed]) == nil)
        #expect(ItemListModel.statusAction(for: []) == nil)
    }

    @Test func splitNeedsASightingCheckedAndOneLeftBehind() {
        func sighting(_ id: String) -> SightingRow {
            SightingRow(id: id, imageID: "i", displayName: nil, capturedAt: Date(), title: "t", confidence: 0.9, citedLines: [], decisionJSON: "{}")
        }
        let all = [sighting("s1"), sighting("s2"), sighting("s3")]
        #expect(ItemListModel.canSplit(checked: ["s1"], of: all))
        #expect(ItemListModel.canSplit(checked: ["s1", "s2"], of: all))
        #expect(ItemListModel.canSplit(checked: [], of: all) == false)
        #expect(ItemListModel.canSplit(checked: ["s1", "s2", "s3"], of: all) == false)
        #expect(ItemListModel.canSplit(checked: ["other"], of: all) == false)
        #expect(ItemListModel.canSplit(checked: ["s1"], of: [sighting("s1")]) == false)
    }

    @Test func undoLastIsTheNewestUserOperationNotUndoneAndNotAnUndo() {
        func op(_ id: String, _ kind: String, byUser: Bool = true, undone: Bool = false) -> OperationSummary {
            OperationSummary(id: id, kind: kind, byUser: byUser, createdAt: Date(), undone: undone)
        }
        let newestFirst = [op("auto", "auto_merge", byUser: false), op("u2", "undo"), op("m2", "merge", undone: true), op("d1", "dismiss"), op("m1", "merge")]
        #expect(ItemListModel.undoTarget(in: newestFirst)?.id == "d1")
        #expect(ItemListModel.undoTarget(in: [op("auto", "auto_merge", byUser: false), op("u", "undo")]) == nil)
        #expect(ItemListModel.undoTarget(in: []) == nil)
    }

    // MARK: lock choice

    @Test func aLockConflictYieldsTheTwoValuesOfEachField() {
        let keep = ItemDetail(item: item("Standup"), fields: [FieldHistory(field: .title, current: .string("Daily standup"), chosenObservationID: "o1", locked: true, entries: [])])
        let other = ItemDetail(item: item("Team sync"), fields: [FieldHistory(field: .title, current: .string("Team sync"), chosenObservationID: "o2", locked: true, entries: [])])
        let choices = ItemListModel.lockChoices(for: [.title], keep: keep, other: other)
        #expect(choices.count == 1)
        #expect(choices[0].field == .title && choices[0].keepValue == "Daily standup" && choices[0].otherValue == "Team sync")
        #expect(choices[0].keepItem == keep.item.id && choices[0].otherItem == other.item.id)
        #expect(choices[0].prompt == "Both items have your value for title. Keep:")
    }

    @Test func valueTextReadsDatesListsAndFlags() {
        let t = ReconcileFixture.nine
        #expect(ItemListModel.valueText(.date(t), field: .start, timezone: "Europe/Madrid") == "Wed 14 Oct 09:00")
        #expect(ItemListModel.valueText(.array([.string("Ana"), .string("Luis")]), field: .people, timezone: "UTC") == "Ana, Luis")
        #expect(ItemListModel.valueText(.bool(true), field: .allDay, timezone: "UTC") == "yes")
        #expect(ItemListModel.valueText(.string("Room 4"), field: .place, timezone: "UTC") == "Room 4")
        #expect(ItemListModel.valueText(nil, field: .notes, timezone: "UTC") == "none")
        #expect(ItemListModel.valueText(.null, field: .end, timezone: "UTC") == "none")
    }

    @Test func sourceWordsAndFieldText() {
        #expect(ItemListModel.sourceText(.read) == "read" && ItemListModel.sourceText(.inferred) == "guessed" && ItemListModel.sourceText(.user) == "you")
        let entry = FieldHistory.Entry(observationID: "o1", value: .string("Standup"), source: .inferred, confidence: 0.7, observedAt: Date(), sightingID: nil, imageID: nil, citedLines: [])
        let field = FieldHistory(field: .title, current: .string("Standup"), chosenObservationID: "o1", locked: false, entries: [entry])
        let text = ItemListModel.fieldText(field, timezone: "UTC")
        #expect(text.value == "Standup" && text.source == "guessed")
    }

    @Test func whyTextShowsTheRuleAndScores() {
        #expect(ItemListModel.whyText(decisionJSON: #"{"rule":"text-time","scores":{"text":1,"time":0.8},"kind":"appointment"}"#) == "text-time (text 1.00, time 0.80)")
        #expect(ItemListModel.whyText(decisionJSON: #"{"rule":"sticky"}"#) == "sticky")
        #expect(ItemListModel.whyText(decisionJSON: #"{"rule":"rerank-yes","scores":{"text":0.3,"time":1,"rerank":0.99}}"#) == "rerank-yes (text 0.30, time 1.00, rerank 0.99)")
        #expect(ItemListModel.whyText(decisionJSON: "not json") == "")
    }

    @Test func operationWordsCoverEveryKind() {
        for kind in ["auto_merge", "merge", "split", "dismiss", "restore", "edit", "unlock", "context", "different", "undo"] {
            #expect(ItemListModel.operationText(kind) != kind)
        }
        #expect(ItemListModel.operationText("new_kind") == "new_kind")
    }

    // MARK: evidence cards

    private func sighting(_ id: String, at seconds: Double) -> SightingRow {
        SightingRow(id: id, imageID: "i-\(id)", displayName: "Display", capturedAt: Date(timeIntervalSince1970: seconds), title: "t-\(id)", confidence: 0.9, citedLines: [1], decisionJSON: "{}")
    }

    private func evidence(_ id: String, sighting: String?, at seconds: Double, reason: String? = nil) -> EvidenceRecord {
        EvidenceRecord(id: id, itemID: "item", sightingID: sighting, imageID: "i-\(sighting ?? id)", capturedAt: Date(timeIntervalSince1970: seconds), displayName: "Display",
                       title: "e-\(id)", citedLines: [1], region: nil, filePath: reason == nil ? "evidence/x.heic" : nil, reason: reason)
    }

    @Test func entriesJoinSightingsAndEvidenceNewestFirst() {
        let entries = ItemListModel.evidenceEntries(
            sightings: [sighting("a", at: 300), sighting("b", at: 100)],
            evidence: [evidence("ea", sighting: "a", at: 300), evidence("gone", sighting: nil, at: 200)])
        #expect(entries.map(\.id) == ["a", "gone", "b"])
        #expect(entries[0].evidence?.id == "ea" && entries[0].sighting?.id == "a")
        #expect(entries[1].sighting == nil && entries[1].title == "e-gone")           // the capture is gone, the cut-out stays
        #expect(entries[2].evidence == nil && entries[2].title == "t-b")               // a sighting from before evidence existed
    }

    @Test func onlyTheFiveNewestShowBeforeShowAll() {
        let entries = ItemListModel.evidenceEntries(sightings: (0..<8).map { sighting("s\($0)", at: Double($0)) }, evidence: [])
        let few = ItemListModel.shownEntries(entries, showAll: false)
        #expect(few.shown.map(\.id) == ["s7", "s6", "s5", "s4", "s3"] && few.moreText == "Show all 8 sightings")
        let all = ItemListModel.shownEntries(entries, showAll: true)
        #expect(all.shown.count == 8 && all.moreText == nil)
        let five = ItemListModel.shownEntries(Array(entries.prefix(5)), showAll: false)
        #expect(five.shown.count == 5 && five.moreText == nil)
    }

    @Test func aMissingCutOutSaysWhy() {
        #expect(ItemListModel.missingCutOutText(evidence("e", sighting: "a", at: 1, reason: "no-lines")) == "No cut-out: the finding cited no lines.")
        #expect(ItemListModel.missingCutOutText(evidence("e", sighting: "a", at: 1, reason: "picture-missing")).contains("no longer stored"))
        #expect(ItemListModel.missingCutOutText(evidence("e", sighting: "a", at: 1, reason: "failed")).contains("could not be made"))
        #expect(ItemListModel.missingCutOutText(nil) == "No cut-out yet.")
        #expect(ItemListModel.missingCutOutText(evidence("e", sighting: "a", at: 1)) == "The cut-out file is gone.")
    }
}
