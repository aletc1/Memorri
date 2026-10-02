import Foundation
import Testing
@testable import MemorriCore

/// What a sync does for each item, decided without touching anything (spec 009, ADR 0026).
@Suite struct SyncPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)
    private var settings: SyncSettings { SyncSettings(calendarID: "cal", listID: "list", now: now) }

    private func plan(_ items: [Item], links: [SyncLink] = [], stored: [StoredEntry] = [], settings: SyncSettings? = nil, context: String? = nil) -> [SyncAction] {
        let byEK = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SyncPlanner.plan(sources: items.map { SyncSource(item: $0, contextName: context) }, links: Dictionary(links.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first }),
                                lookup: { byEK[$0.ekID] }, settings: settings ?? self.settings).actions
    }

    /// The link and stored entry of an item as if it had just been written.
    private func written(_ item: Item, ek: String = "E1", container: String = "cal", state: SyncLinkState = .synced, context: String? = nil) -> (SyncLink, StoredEntry) {
        let entry = SyncRender.render(SyncSource(item: item, contextName: context))
        return (SyncLink(itemID: item.id, kind: entry.kind, ekID: ek, containerID: container, hash: SyncRender.hash(entry), hashVersion: SyncRender.hashVersion, fields: entry,
                         state: state, syncedAt: now), StoredEntry(id: ek, containerID: container, entry: entry))
    }

    @Test func readyItemsAreCreatedInTheChosenCalendarAndList() {
        let event = syncItem("e"), task = syncItem("t", kind: .task, start: nil, due: now)
        let actions = plan([event, task])
        guard case .create(_, let e, let container)? = actions.first, case .create(_, let t, let list)? = actions.last else { Issue.record("expected creates, got \(actions)"); return }
        #expect(container == "cal" && e.kind == .event && list == "list" && t.kind == .reminder)
    }

    @Test func anItemInTheInboxIsNotWrittenUntilApproved() {
        #expect(plan([syncItem(needsReview: true)]) == [.skip(itemID: "i1", reason: .inbox)])
        #expect(plan([syncItem(needsReview: false, approved: true)]).first.map { if case .create = $0 { true } else { false } } == true)
    }

    @Test func dismissedAndMergedItemsWithoutAnEntryAreLeftAlone() {
        #expect(plan([syncItem(status: .dismissed)]) == [.skip(itemID: "i1", reason: .notReady)])
        #expect(plan([syncItem(status: .merged)]) == [.skip(itemID: "i1", reason: .notReady)])
    }

    @Test func anEventWithoutADateIsNotWrittenButATaskWithoutOneIsUndated() {
        #expect(plan([syncItem("e", start: nil)]) == [.skip(itemID: "e", reason: .noDate)])
        guard case .create(_, let entry, _)? = plan([syncItem("t", kind: .task, start: nil, due: nil)]).first else { Issue.record("expected a create"); return }
        #expect(entry.due == nil && entry.kind == .reminder)
    }

    @Test func itemsOlderThanNinetyDaysAreNotWrittenButAnExistingEntryIsLeftAlone() {
        let old = syncItem("o", start: now.addingTimeInterval(-91 * 86_400)), recent = syncItem("r", start: now.addingTimeInterval(-89 * 86_400))
        #expect(plan([old]) == [.skip(itemID: "o", reason: .tooOld)])
        #expect(plan([recent]).first.map { if case .create = $0 { true } else { false } } == true)
        let (link, stored) = written(old)
        #expect(plan([old], links: [link], stored: [stored]) == [.skip(itemID: "o", reason: .unchanged)])
    }

    @Test func withNoCalendarOrNoListNothingIsPlannedForThatKind() {
        var noCalendar = settings; noCalendar.calendarID = nil
        #expect(plan([syncItem("e")], settings: noCalendar) == [.skip(itemID: "e", reason: .noCalendar)])
        var noList = settings; noList.listID = nil
        #expect(plan([syncItem("t", kind: .task, start: nil, due: now)], settings: noList) == [.skip(itemID: "t", reason: .noList)])
        #expect(plan([syncItem("e")], settings: noList).first.map { if case .create = $0 { true } else { false } } == true)
    }

    @Test func aSecondPlanAfterTheWriteDoesNothingAndAChangeIsAnUpdateOfTheSameEntry() {
        let item = syncItem(title: "Standup", end: now.addingTimeInterval(3600))
        let (link, stored) = written(item)
        #expect(plan([item], links: [link], stored: [stored]) == [.skip(itemID: "i1", reason: .unchanged)])
        var moved = item; moved.end = now.addingTimeInterval(7200); moved.title = "Daily standup"
        guard case .update(let id, let entry, let changed)? = plan([moved], links: [link], stored: [stored]).first else { Issue.record("expected update"); return }
        #expect(id == "i1" && entry.title == "Daily standup" && changed == ["title", "end"])
    }

    @Test func aDismissedOrMergedItemWithAnEntryIsRemovedAndRestoringItWritesItAgain() {
        let item = syncItem()
        let (link, stored) = written(item)
        #expect(plan([syncItem(status: .dismissed)], links: [link], stored: [stored]) == [.remove(itemID: "i1", reason: "dismissed")])
        #expect(plan([syncItem(status: .merged)], links: [link], stored: [stored]) == [.remove(itemID: "i1", reason: "merged")])
        var removed = link; removed.state = .removed
        #expect(plan([syncItem(status: .dismissed)], links: [removed]) == [])                       // already removed
        guard case .create? = plan([item], links: [removed]).first else { Issue.record("a restored item is written again"); return }
    }

    @Test func anItemBackInTheInboxKeepsItsEntryAsItIs() {
        let item = syncItem()
        let (link, stored) = written(item)
        #expect(plan([syncItem(needsReview: true)], links: [link], stored: [stored]) == [.skip(itemID: "i1", reason: .inbox)])
    }

    @Test func anEntryDeletedOrMovedByTheUserIsNotRecreated() {
        let item = syncItem()
        let (link, _) = written(item)
        #expect(plan([item], links: [link], stored: []) == [.markRemovedByUser(itemID: "i1", reason: "deleted")])
        let moved = StoredEntry(id: "E1", containerID: "cal-work", entry: link.fields)
        #expect(plan([item], links: [link], stored: [moved]) == [.markRemovedByUser(itemID: "i1", reason: "moved")])
        var gone = link; gone.state = .removedByUser
        #expect(plan([item], links: [gone]) == [.skip(itemID: "i1", reason: .removedByUser)])
    }

    @Test func aCompletedReminderStaysCompleted() {
        let task = syncItem("t", kind: .task, start: nil, due: now)
        var (link, stored) = written(task, ek: "R1", container: "list")
        stored.completed = true
        #expect(plan([task], links: [link], stored: [stored]) == [.complete(itemID: "t")])
        link.state = .completed
        #expect(plan([task], links: [link], stored: [stored]) == [.skip(itemID: "t", reason: .completed)])
    }

    @Test func anEditMadeInCalendarIsAdoptedBeforeAnythingIsWrittenOver() {
        let item = syncItem(title: "Standup", end: now.addingTimeInterval(3600))
        let (link, stored) = written(item, context: "Acme")
        var edited = stored; edited.entry.title = "[Acme] Daily standup"; edited.entry.start = now.addingTimeInterval(1800)
        let actions = plan([item], links: [link], stored: [edited], context: "Acme")
        #expect(actions == [.adopt(itemID: "i1", fields: [.title: .string("Daily standup"), .start: .date(now.addingTimeInterval(1800))])])
    }

    @Test func choosingAnotherCalendarPlansAMoveOfTheEntriesAlreadyWritten() {
        let item = syncItem()
        let (link, stored) = written(item, container: "cal-old")
        guard case .move(let id, _, let from, let to)? = plan([item], links: [link], stored: [stored]).first else { Issue.record("expected a move"); return }
        #expect(id == "i1" && from == "cal-old" && to == "cal")
    }

    @Test func aPlanCountsWhatItWouldDo() {
        let a = syncItem("a"), b = syncItem("b", needsReview: true)
        let plan = SyncPlan(actions: plan([a, b]))
        #expect(plan.created == 1 && plan.skipped == 1 && plan.hasWork)
        #expect(!SyncPlan(actions: [.skip(itemID: "x", reason: .unchanged)]).hasWork)
    }
}
