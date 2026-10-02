import Foundation

/// The words the Calendar sync settings and the item detail use (spec 009), kept pure so they are tested.
public enum SyncWords {
    public static func problem(_ problem: SyncProblem) -> String {
        switch problem {
        case .noAccess(let kind): kind == .event ? "Memorri has no access to Calendar. Allow it in Settings first." : "Memorri has no access to Reminders. Allow it in Settings first."
        case .targetGone(let kind): kind == .event ? "The chosen calendar no longer exists. Choose another one." : "The chosen list no longer exists. Choose another one."
        case .notSetUp: "Choose a calendar or a list first."
        }
    }

    public static func reason(_ reason: SyncSkipReason) -> String {
        switch reason {
        case .inbox: "it waits in the Inbox"
        case .notReady: "it is dismissed or merged"
        case .noDate: "it has no date"
        case .tooOld: "it is more than 90 days old"
        case .noCalendar: "no calendar is chosen"
        case .noList: "no list is chosen"
        case .unchanged: "nothing changed"
        case .removedByUser: "you deleted it in Calendar or Reminders"
        case .completed: "completed in Reminders"
        }
    }

    public static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    /// `Created 3 · updated 1 · removed 0 · took over 1 · skipped 2 · failed 0`, with `Preview` in front of a preview.
    public static func summary(_ run: SyncRunRecord) -> String {
        var parts = ["created \(run.created)", "updated \(run.updated)", "removed \(run.removed)"]
        if run.adopted > 0 { parts.append("took over \(run.adopted) from Calendar") }
        parts.append("skipped \(run.skipped)"); parts.append("failed \(run.failed)")
        let text = parts.joined(separator: " · ")
        return (run.preview ? "Preview: " : "") + text
    }

    /// The status line under the switch.
    public static func status(enabled: Bool, confirmed: Bool, outcome: SyncOutcome?, lastRun: SyncRunRecord?, now: Date) -> String {
        if !enabled { return "Sync is off." }
        if let issue = outcome?.problem { return problem(issue) }
        if !confirmed { return "Waiting for you: look at the preview, then press Sync now. Nothing is written before that." }
        guard let run = lastRun else { return "Waiting for the first run." }
        if run.failed > 0 { return "Synced \(age(run.finishedAt, now: now)), \(run.failed) \(run.failed == 1 ? "item" : "items") could not be written." }
        return "Synced \(age(run.finishedAt, now: now))."
    }

    public struct PreviewGroup: Equatable, Identifiable, Sendable {
        public let title: String
        public let lines: [String]
        public var id: String { title }
    }

    /// What a sync would do, grouped, with item titles and the fields that change. `unchanged` items are not listed, only counted by `leftAlone`.
    public static func preview(_ plan: SyncPlan, titles: [String: String]) -> [PreviewGroup] {
        func name(_ id: String) -> String { titles[id] ?? "an item" }
        var creates: [String] = [], updates: [String] = [], removes: [String] = [], adopts: [String] = [], leaves: [String] = [], moves: [String] = []
        for action in plan.actions {
            switch action {
            case .create(_, let entry, _): creates.append(entry.title)
            case .update(let id, _, let changed): updates.append("\(name(id)) (\(changed.joined(separator: ", ")))")
            case .move(let id, _, _, _): moves.append(name(id))
            case .remove(let id, let why): removes.append("\(name(id)) (\(why))")
            case .adopt(let id, let fields): adopts.append("\(name(id)) (\(fields.keys.map(\.rawValue).sorted().joined(separator: ", ")))")
            case .skip(let id, let why) where why != .unchanged && why != .notReady && why != .completed && why != .removedByUser: leaves.append("\(name(id)): \(reason(why))")
            case .complete, .markRemovedByUser, .skip: break
            }
        }
        var groups: [PreviewGroup] = []
        func add(_ title: String, _ lines: [String]) { if !lines.isEmpty { groups.append(PreviewGroup(title: "\(title) (\(lines.count))", lines: lines)) } }
        add("Create", creates); add("Update", updates); add("Move to the new calendar or list", moves); add("Remove", removes)
        add("Take over from Calendar or Reminders", adopts); add("Leave out", leaves)
        return groups
    }

    /// The row of the item detail: whether and when the item is in Calendar or Reminders, or why not.
    public static func itemLine(item: Item, link: SyncLink?, enabled: Bool, now: Date, zone: TimeZone = .current) -> String? {
        let place = (link?.kind ?? SyncRender.kind(of: item)) == .event ? "Calendar" : "Reminders"
        if let link {
            switch link.state {
            case .synced:
                let formatter = DateFormatter(); formatter.timeZone = zone; formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = Calendar.current.isDate(link.syncedAt, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
                formatter.timeZone = zone
                return "\(place): synced \(formatter.string(from: link.syncedAt))"
            case .completed: return "\(place): completed in Reminders"
            case .removedByUser: return "\(place): not synced, you deleted the entry there"
            case .removed: return item.status == .active ? "\(place): not synced yet" : "\(place): removed because the item is \(item.status == .dismissed ? "dismissed" : "merged")"
            case .failed: return "\(place): not synced" + (link.failure.map { ", \($0)" } ?? "")
            }
        }
        guard enabled else { return nil }
        if item.status != .active { return nil }
        if item.needsReview { return "\(place): not synced, \(reason(.inbox))" }
        if ItemListModel.moment(item) == nil && SyncRender.kind(of: item) == .event { return "\(place): not synced, \(reason(.noDate))" }
        return "\(place): not synced yet"
    }
}
