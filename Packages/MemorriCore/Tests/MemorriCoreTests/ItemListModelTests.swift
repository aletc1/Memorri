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
        #expect(Set(titles(ItemFilter(kind: .tasks))) == ["Pay rent"])             // reminders have their own filter (spec 006)
        #expect(Set(titles(ItemFilter(kind: .reminders))) == ["Call"])
        #expect(titles(ItemFilter(context: .context("a"))) == ["Pay rent"])
        #expect(titles(ItemFilter(context: .none)) == ["Standup"])
        #expect(Set(titles(ItemFilter(kind: .reminders, context: .context("b")))) == ["Call"])
        #expect(titles(ItemFilter(kind: .tasks, context: .context("b"))).isEmpty)
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

    // MARK: review scope (spec 006, US2)

    private func reviewed(_ title: String, reasons: [ReviewReason] = [], approved: Bool = false, status: ItemStatus = .active, lastSeen: TimeInterval = 0,
                          start: Date? = ReconcileFixture.nine) -> ItemRow {
        var made = item(title, start: start, status: status)
        made.reviewReasons = reasons
        made.needsReview = !reasons.isEmpty && status == .active
        made.approvedAt = approved ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        made.lastSeen = Date(timeIntervalSince1970: 1_800_000_000 + lastSeen)
        return row(made)
    }

    @Test func theInboxListsOnlyItemsNeedingReviewNewestSightingFirst() {
        let rows = [reviewed("Older", reasons: [.lowConfidence], lastSeen: 10), reviewed("Fine"), reviewed("Newer", reasons: [.guessedEnd], lastSeen: 50),
                    reviewed("Dismissed", reasons: [.lowConfidence], status: .dismissed, lastSeen: 99),
                    reviewed("Undated newest", reasons: [.possibleDuplicate], lastSeen: 80, start: nil)]
        let inbox = ItemListModel.visible(rows, filter: ItemFilter(scope: .inbox, showDismissed: true))
        #expect(inbox.map(\.item.title) == ["Undated newest", "Newer", "Older"])
    }

    @Test func theApprovedScopeListsActiveItemsThatDoNotNeedReview() {
        let rows = [reviewed("Fine"), reviewed("Checked", approved: true), reviewed("Doubtful", reasons: [.lowConfidence]),
                    reviewed("Dismissed", status: .dismissed)]
        #expect(Set(ItemListModel.visible(rows, filter: ItemFilter(scope: .approved, showDismissed: true)).map(\.item.title)) == ["Fine", "Checked"])
        #expect(Set(ItemListModel.visible(rows, filter: ItemFilter(scope: .all)).map(\.item.title)) == ["Fine", "Checked", "Doubtful"])
    }

    @Test func theScopesWorkWithTheKindAndContextFilters() {
        var a = reviewed("In context", reasons: [.lowConfidence]).item
        a.contextID = "a"
        var b = reviewed("Other context", reasons: [.lowConfidence]).item
        b.contextID = "b"
        let rows = [row(a), row(b), reviewed("Task", reasons: [.lowConfidence])]
        #expect(ItemListModel.visible(rows, filter: ItemFilter(context: .context("a"), scope: .inbox)).map(\.item.title) == ["In context"])
        #expect(ItemListModel.visible(rows, filter: ItemFilter(context: .none, scope: .inbox)).map(\.item.title) == ["Task"])
    }

    @Test func reasonsAreShownInWords() {
        #expect(ItemListModel.reviewText([.lowConfidence, .guessedStart, .guessedEnd, .guessedDue, .possibleDuplicate, .changedAfterApproval, .possiblyCancelled])
                == ["Low confidence", "Guessed time", "Guessed end", "Guessed due date", "Possible duplicate", "Changed after you approved it", "Possibly cancelled"])
        #expect(ItemListModel.reviewText([]).isEmpty)
    }

    @Test func approvalIsShownInWords() {
        #expect(ItemListModel.approvalText(reviewed("a", reasons: [.lowConfidence]).item) == "Needs review")
        #expect(ItemListModel.approvalText(reviewed("b").item) == "Approved")
        #expect(ItemListModel.approvalText(reviewed("c", approved: true).item) == "Approved by you")
        #expect(ItemListModel.approvalText(reviewed("d", status: .dismissed).item) == "Dismissed")
        let text = ItemListModel.rowText(reviewed("e", reasons: [.guessedEnd]), contextName: nil)
        #expect(text.approval == "Needs review" && text.reasons == ["Guessed end"])
    }

    @Test func approveIsOfferedWhenEverySelectedItemNeedsReview() {
        let doubtful = reviewed("a", reasons: [.lowConfidence]), fine = reviewed("b")
        #expect(ItemListModel.canApprove([doubtful]) && ItemListModel.canApprove([doubtful, reviewed("c", reasons: [.guessedEnd])]))
        #expect(!ItemListModel.canApprove([doubtful, fine]) && !ItemListModel.canApprove([fine]) && !ItemListModel.canApprove([]))
    }

    @Test func theEmptyStatesNameTheScope() {
        #expect(ItemListModel.emptyText(scope: .inbox) == "Nothing needs review.")
        #expect(ItemListModel.emptyText(scope: .all) == "No items yet. Items appear after captures are analysed.")
        #expect(ItemListModel.emptyText(scope: .approved) == "No approved items yet.")
    }

    @Test func approvalsAreUndoableAndWorded() {
        let ops = [OperationSummary(id: "2", kind: "approve", byUser: true, createdAt: Date(), undone: false),
                   OperationSummary(id: "1", kind: "edit", byUser: true, createdAt: Date(), undone: false)]
        #expect(ItemListModel.undoTarget(in: ops)?.id == "2")
        #expect(ItemListModel.operationText("approve") == "Approved")
    }

    // MARK: parsing an edit (spec 006, US3)

    private func parsed(_ text: String, _ field: ItemField, zone: String = "Europe/Madrid") -> JSONValue? {
        if case .success(let value) = ItemListModel.parse(text, field: field, timezone: zone) { value } else { nil }
    }
    private func failure(_ text: String, _ field: ItemField, zone: String = "Europe/Madrid") -> EditError? {
        if case .failure(let error) = ItemListModel.parse(text, field: field, timezone: zone) { error } else { nil }
    }

    @Test func datesAreReadInTheItemsOwnZone() {
        // 09:00 in Madrid in October (UTC+2) is 07:00 UTC; the same wall clock in New York (UTC-4) is 13:00 UTC.
        #expect(parsed("2026-10-14 09:00", .start) == .date(ReconcileFixture.nine))
        #expect(parsed("2026-10-14 09:00", .start, zone: "America/New_York") == .date(ReconcileFixture.nine.addingTimeInterval(6 * 3600)))
        #expect(parsed("  2026-10-14 09:00 ", .end) == .date(ReconcileFixture.nine))
        #expect(parsed("2026-10-14", .due) == .date(ReconcileFixture.nine.addingTimeInterval(-9 * 3600)))
    }

    @Test func anInvalidDateIsRefusedWithAMessage() {
        for text in ["tomorrow", "2026-13-40 09:00", "09:00", "2026-10-14 25:00"] {
            #expect(failure(text, .start) == .invalidDate)
        }
        #expect(failure("", .start) == .invalidDate)               // a start cannot be cleared
        #expect(!EditError.invalidDate.message.isEmpty && EditError.invalidDate.message.contains("2026-10-14 09:00"))
    }

    @Test func anEmptyOptionalFieldMeansClear() {
        for field in [ItemField.end, .due, .remind, .place, .notes] { #expect(parsed("  ", field) == .null) }
        #expect(parsed("", .people) == .array([]))
    }

    @Test func titlePlaceAndNotesAreTrimmedAndATitleCannotBeEmpty() {
        #expect(parsed("  Standup \n", .title) == .string("Standup"))
        #expect(parsed(" Room 4 ", .place) == .string("Room 4"))
        #expect(parsed("line one\nline two  ", .notes) == .string("line one\nline two"))
        #expect(failure("   ", .title) == .emptyTitle)
        #expect(EditError.emptyTitle.message == "The title cannot be empty.")
    }

    @Test func peopleAreSplitOnCommasTrimmedAndDeDuplicated() {
        #expect(parsed("Anna, Ben ,, anna,  ", .people) == .array([.string("Anna"), .string("Ben")]))
    }

    @Test func theAllDayFlagIsReadAsYesOrNo() {
        #expect(parsed("yes", .allDay) == .bool(true) && parsed("No", .allDay) == .bool(false))
        #expect(failure("maybe", .allDay) == .invalidValue)
    }

    @Test func theEditorsInitialTextRoundTripsThroughParse() {
        let zone = "Europe/Madrid"
        let cases: [(ItemField, JSONValue)] = [(.title, .string("Standup")), (.start, .date(ReconcileFixture.nine)), (.end, .date(ReconcileFixture.minutes(90))),
                                               (.due, .date(ReconcileFixture.minutes(600))), (.people, .array([.string("Anna"), .string("Ben")])),
                                               (.place, .string("Room 4")), (.notes, .string("agenda"))]
        for (field, value) in cases {
            let text = ItemListModel.editText(value, field: field, timezone: zone)
            #expect(parsed(text, field, zone: zone) == value, "\(field)")
        }
        #expect(ItemListModel.editText(nil, field: .place, timezone: zone) == "" && ItemListModel.editText(.null, field: .end, timezone: zone) == "")
        #expect(ItemListModel.editText(.date(ReconcileFixture.nine), field: .start, timezone: zone) == "2026-10-14 09:00")
    }

    // MARK: kinds, scopes and the count (spec 006, US4)

    @Test func eachKindFilterListsOnlyItsKinds() {
        let rows = [row(item("Standup")), row(item("Pay rent", kind: .task, start: nil, due: ReconcileFixture.nine)),
                    row(item("Contract", kind: .deadline, start: nil, due: ReconcileFixture.nine)), row(item("Call", kind: .reminder, start: nil))]
        func titles(_ kind: ItemKindFilter) -> Set<String> { Set(ItemListModel.visible(rows, filter: ItemFilter(kind: kind)).map(\.item.title)) }
        #expect(titles(.all) == ["Standup", "Pay rent", "Contract", "Call"])
        #expect(titles(.appointments) == ["Standup"])
        #expect(titles(.tasks) == ["Pay rent", "Contract"])
        #expect(titles(.reminders) == ["Call"])
        #expect(ItemKindFilter.allCases == [.all, .appointments, .tasks, .reminders])
    }

    @Test func theInboxCombinesWithKindAndContextAndItsCountIsWhatItLists() {
        var rows: [ItemRow] = []
        for (title, kind, context, doubtful) in [("A1", FindingKind.appointment, "a", true), ("A2", .appointment, "a", false), ("T1", .task, "a", true),
                                                  ("R1", .reminder, "b", true), ("R2", .reminder, nil, true), ("T2", .task, "b", true)] as [(String, FindingKind, String?, Bool)] {
            var made = item(title, kind: kind, start: kind == .appointment ? ReconcileFixture.nine : nil, context: context)
            made.needsReview = doubtful
            made.reviewReasons = doubtful ? [.lowConfidence] : []
            rows.append(row(made))
        }
        func listed(_ filter: ItemFilter) -> Set<String> { Set(ItemListModel.visible(rows, filter: filter).map(\.item.title)) }
        #expect(listed(ItemFilter(scope: .inbox)) == ["A1", "T1", "R1", "R2", "T2"])
        #expect(listed(ItemFilter(kind: .reminders, scope: .inbox)) == ["R1", "R2"])
        #expect(listed(ItemFilter(kind: .tasks, context: .context("b"), scope: .inbox)) == ["T2"])
        #expect(listed(ItemFilter(context: .none, scope: .inbox)) == ["R2"])
        for filter in [ItemFilter(), ItemFilter(context: .context("a")), ItemFilter(kind: .tasks), ItemFilter(kind: .reminders, context: .none)] {
            #expect(ItemListModel.inboxCount(rows, filter: filter) == listed(ItemFilter(kind: filter.kind, context: filter.context, scope: .inbox)).count)
        }
    }

    @Test func theScopeLabelCountEqualsTheStoresReviewCountForTheSameContext() async throws {
        let fixture = try ReconcileFixture(); defer { fixture.cleanUp() }
        try fixture.addContext("a", "A"); try fixture.addContext("b", "B")
        let reconciler = Reconciler(database: fixture.database, judge: NoMeaningJudge(), now: { Date(timeIntervalSince1970: 1_800_100_000) })
        let specs: [(String, Double, String?)] = [("Standup", 0.6, "a"), ("Lunch", 0.9, "a"), ("Dentist", 0.6, "b"), ("Review", 0.5, nil)]
        for (index, (title, confidence, context)) in specs.enumerated() {
            let picture = index == 0 ? fixture.base.imageID : try fixture.addPicture(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 7200))
            try fixture.save([fixture.finding(title, start: ReconcileFixture.minutes(index * 300), confidence: confidence)], imageID: picture, contextID: context)
            _ = await reconciler.reconcile(imageID: picture)
        }
        let store = ItemStore(database: fixture.database)
        let rows = try store.items(status: [.active, .dismissed], kinds: nil, contextID: nil)
        for (filter, context) in [(ItemContextFilter.all, String??.none), (.context("a"), .some("a")), (.context("b"), .some("b")), (.none, .some(nil))] {
            #expect(ItemListModel.inboxCount(rows, filter: ItemFilter(context: filter)) == (try store.reviewCount(contextID: context)))
        }
        #expect(try store.reviewCount() == 3)
    }

    // MARK: provenance (spec 006, FR-005)

    private func history(_ entries: [(String, JSONValue, ObservationSource, String?, TimeInterval)], chosen: String?, locked: Bool = false) -> FieldHistory {
        FieldHistory(field: .place, current: nil, chosenObservationID: chosen, locked: locked,
                     entries: entries.map { FieldHistory.Entry(observationID: $0.0, value: $0.1, source: $0.2, confidence: 0.8,
                                                                observedAt: Date(timeIntervalSince1970: 1_791_961_200 + $0.4), sightingID: $0.3, imageID: nil, citedLines: []) })
    }

    @Test func everyValueBehindAFieldIsListedWithItsSourceAndTheCurrentOneMarked() {
        let field = history([("c", .string("Room 4"), .read, "s2", 7200), ("b", .string("Room 9"), .user, nil, 3600), ("a", .string("Room 3"), .inferred, "s1", 0)],
                            chosen: "b", locked: true)
        let rows = ItemListModel.provenance(field, timezone: "UTC")
        #expect(rows.map(\.value) == ["Room 4", "Room 9", "Room 3"])
        #expect(rows.map(\.source) == ["read", "you", "guessed"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows.map(\.confidence) == ["0.80", nil, "0.80"])
        #expect(rows[1].when == "Wed 14 Oct 08:00")
    }

    @Test func theSightingBehindTheCurrentValueIsKnownUnlessTheUserSetIt() {
        let seen = history([("a", .string("Room 4"), .read, "s1", 0), ("b", .string("Room 9"), .read, "s2", 3600)], chosen: "b")
        #expect(ItemListModel.sourceSightingID(seen) == "s2")
        let set = history([("a", .string("Room 4"), .read, "s1", 0), ("u", .string("Room 9"), .user, nil, 3600)], chosen: "u", locked: true)
        #expect(ItemListModel.sourceSightingID(set) == nil)
        #expect(ItemListModel.sourceSightingID(nil) == nil)
        #expect(ItemListModel.sourceSightingID(history([], chosen: nil)) == nil)
    }

    // MARK: window text (spec 011)

    @Test func windowTextNamesTheApplicationAndTheTitle() {
        var s = sighting("a", at: 1); s.windowApp = "Calendar"; s.windowTitle = "Work week"
        #expect(ItemListModel.windowText(EvidenceEntry(sighting: s, evidence: nil)) == "Calendar — Work week")
        s.windowTitle = nil
        #expect(ItemListModel.windowText(EvidenceEntry(sighting: s, evidence: nil)) == "Calendar")
        s.windowTitle = "  "
        #expect(ItemListModel.windowText(EvidenceEntry(sighting: s, evidence: nil)) == "Calendar")
    }

    @Test func windowTextIsNilWithoutAWindowAndComesFromTheCutOutWhenTheSightingIsGone() {
        #expect(ItemListModel.windowText(EvidenceEntry(sighting: sighting("a", at: 1), evidence: evidence("e", sighting: "a", at: 1))) == nil)
        var e = evidence("e", sighting: nil, at: 1); e.windowApp = "Mail"; e.windowTitle = "Inbox"
        #expect(ItemListModel.windowText(EvidenceEntry(sighting: nil, evidence: e)) == "Mail — Inbox")
    }

    // MARK: opening an item from search (spec 007)

    @Test func theFilterThatShowsAnItemIsTheWideOneAndShowsDismissedOnlyWhenNeeded() {
        let active = item("Standup"), dismissed = item("Old", status: .dismissed, context: "a")
        var review = item("Doubtful"); review.needsReview = true
        let rows = [row(active), row(dismissed), row(review)]
        for target in [active, dismissed, review] {
            let filter = ItemListModel.filter(showing: target.status)
            #expect(ItemListModel.visible(rows, filter: filter).contains { $0.item.id == target.id }, "\(target.title)")
            #expect(filter.scope == .all && filter.kind == .all && filter.context == .all)
        }
        #expect(ItemListModel.filter(showing: active.status).showDismissed == false)
        #expect(ItemListModel.filter(showing: dismissed.status).showDismissed == true)
    }

    // MARK: the search field (spec 007)

    @Test func restrictingKeepsTheMatchingRowsInTheOrderOfTheIds() {
        let a = row(item("Alpha")), b = row(item("Beta")), c = row(item("Gamma"))
        let ranked = [c.item.id, a.item.id, "gone"]
        #expect(ItemListModel.restrict([a, b, c], to: ranked).map(\.item.title) == ["Gamma", "Alpha"])
        #expect(ItemListModel.restrict([a, b, c], to: nil).map(\.item.title) == ["Alpha", "Beta", "Gamma"])      // no search: the list as it is
        #expect(ItemListModel.restrict([a, b, c], to: []).isEmpty)
    }
}
