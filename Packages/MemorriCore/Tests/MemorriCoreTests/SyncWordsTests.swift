import Foundation
import Testing
@testable import MemorriCore

@Suite struct SyncWordsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func problemsAreSaidInPlainWords() {
        #expect(SyncWords.problem(.noAccess(.event)).contains("Calendar") && SyncWords.problem(.noAccess(.reminder)).contains("Reminders"))
        #expect(SyncWords.problem(.targetGone(.event)).contains("calendar") && SyncWords.problem(.notSetUp).contains("Choose"))
    }

    @Test func ageIsShortAndRelative() {
        #expect(SyncWords.age(now, now: now) == "just now")
        #expect(SyncWords.age(now.addingTimeInterval(-180), now: now) == "3 min ago")
        #expect(SyncWords.age(now.addingTimeInterval(-7_300), now: now) == "2 h ago")
        #expect(SyncWords.age(now.addingTimeInterval(-3 * 86_400), now: now) == "3 d ago")
    }

    @Test func aRunIsSummarisedAndAPreviewSaysSo() {
        var run = SyncRunRecord(startedAt: now, finishedAt: now, preview: false)
        run.created = 3; run.skipped = 2
        #expect(SyncWords.summary(run) == "created 3 · updated 0 · removed 0 · skipped 2 · failed 0")
        run.adopted = 1
        #expect(SyncWords.summary(run).contains("took over 1 from Calendar"))
        let preview = SyncRunRecord(startedAt: now, finishedAt: now, preview: true)
        #expect(SyncWords.summary(preview).hasPrefix("Preview: "))
    }

    @Test func theStatusLineFollowsTheState() {
        var run = SyncRunRecord(startedAt: now, finishedAt: now.addingTimeInterval(-180), preview: false)
        #expect(SyncWords.status(enabled: false, confirmed: true, outcome: nil, lastRun: nil, now: now) == "Sync is off.")
        #expect(SyncWords.status(enabled: true, confirmed: false, outcome: nil, lastRun: nil, now: now).contains("Nothing is written before that"))
        #expect(SyncWords.status(enabled: true, confirmed: true, outcome: nil, lastRun: nil, now: now) == "Waiting for the first run.")
        #expect(SyncWords.status(enabled: true, confirmed: true, outcome: nil, lastRun: run, now: now) == "Synced 3 min ago.")
        run.failed = 2
        #expect(SyncWords.status(enabled: true, confirmed: true, outcome: nil, lastRun: run, now: now).contains("2 items could not be written"))
        let blocked = SyncOutcome(plan: SyncPlan(actions: []), run: run, problem: .noAccess(.event))
        #expect(SyncWords.status(enabled: true, confirmed: true, outcome: blocked, lastRun: run, now: now).contains("no access to Calendar"))
    }

    @Test func thePreviewGroupsWhatWouldHappenAndLeavesOutWhatIsUnchanged() {
        let entry = RenderedEntry.sample(.event, title: "Standup")
        let plan = SyncPlan(actions: [
            .create(itemID: "a", entry: entry, containerID: "cal"),
            .update(itemID: "b", entry: entry, changed: ["title", "end"]),
            .remove(itemID: "c", reason: "dismissed"),
            .adopt(itemID: "d", fields: [.title: .string("x"), .start: .date(now)]),
            .skip(itemID: "e", reason: .noDate), .skip(itemID: "f", reason: .unchanged), .skip(itemID: "g", reason: .inbox)])
        let groups = SyncWords.preview(plan, titles: ["b": "Budget", "c": "Old", "d": "Review", "e": "Undated", "g": "Waiting"])
        #expect(groups.map(\.title) == ["Create (1)", "Update (1)", "Remove (1)", "Take over from Calendar or Reminders (1)", "Leave out (2)"])
        #expect(groups[0].lines == ["Standup"] && groups[1].lines == ["Budget (title, end)"] && groups[2].lines == ["Old (dismissed)"])
        #expect(groups[3].lines == ["Review (start, title)"] && groups[4].lines == ["Undated: it has no date", "Waiting: it waits in the Inbox"])
        #expect(SyncWords.preview(SyncPlan(actions: [.skip(itemID: "f", reason: .unchanged)]), titles: [:]).isEmpty)
    }

    @Test func theItemRowSaysWhereTheItemIsOrWhyItIsNot() {
        var zone = TimeZone(identifier: "UTC")!; zone = TimeZone(identifier: "UTC") ?? zone
        let item = syncItem()
        func link(_ state: SyncLinkState, failure: String? = nil, at date: Date? = nil) -> SyncLink {
            let entry = RenderedEntry.sample(.event)
            return SyncLink(itemID: "i1", kind: .event, ekID: "E", containerID: "c", hash: "h", hashVersion: 1, fields: entry, state: state, failure: failure, syncedAt: date ?? now)
        }
        let later = now.addingTimeInterval(3600)
        #expect(SyncWords.itemLine(item: item, link: link(.synced), enabled: true, now: later, zone: zone)?.hasPrefix("Calendar: synced ") == true)
        #expect(SyncWords.itemLine(item: item, link: link(.removedByUser), enabled: true, now: later) == "Calendar: not synced, you deleted the entry there")
        #expect(SyncWords.itemLine(item: item, link: link(.failed, failure: "no calendar is chosen"), enabled: true, now: later) == "Calendar: not synced, no calendar is chosen")
        let task = syncItem("t", kind: .task, start: nil, due: now)
        #expect(SyncWords.itemLine(item: task, link: nil, enabled: true, now: later) == "Reminders: not synced yet")
        #expect(SyncWords.itemLine(item: syncItem(needsReview: true), link: nil, enabled: true, now: later) == "Calendar: not synced, it waits in the Inbox")
        #expect(SyncWords.itemLine(item: item, link: nil, enabled: false, now: later) == nil)
        #expect(SyncWords.itemLine(item: syncItem(status: .dismissed), link: nil, enabled: true, now: later) == nil)
        var done = task; done.status = .active
        let completed = SyncLink(itemID: "t", kind: .reminder, ekID: "R", containerID: "l", hash: "h", hashVersion: 1, fields: .sample(.reminder), state: .completed, syncedAt: now)
        #expect(SyncWords.itemLine(item: done, link: completed, enabled: true, now: later) == "Reminders: completed in Reminders")
    }
}
