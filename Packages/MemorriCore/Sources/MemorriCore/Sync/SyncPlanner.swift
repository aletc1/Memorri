import Foundation

public enum SyncSkipReason: String, Sendable, Equatable {
    case inbox, notReady = "not-ready", noDate = "no-date", tooOld = "too-old", noCalendar = "no-calendar", noList = "no-list"
    case unchanged, removedByUser = "removed-by-user", completed
}

/// One thing sync would do for one item.
public enum SyncAction: Sendable, Equatable {
    case create(itemID: String, entry: RenderedEntry, containerID: String)
    case update(itemID: String, entry: RenderedEntry, changed: [String])
    /// The entry is in the old calendar or list; it moves to the chosen one (only when the user confirmed the move).
    case move(itemID: String, entry: RenderedEntry, from: String, to: String)
    case remove(itemID: String, reason: String)
    case adopt(itemID: String, fields: [ItemField: JSONValue])
    case complete(itemID: String)
    case markRemovedByUser(itemID: String, reason: String)
    case skip(itemID: String, reason: SyncSkipReason)

    public var itemID: String {
        switch self {
        case .create(let id, _, _), .update(let id, _, _), .move(let id, _, _, _), .remove(let id, _), .adopt(let id, _),
             .complete(let id), .markRemovedByUser(let id, _), .skip(let id, _): id
        }
    }
}

public struct SyncPlan: Sendable, Equatable {
    public let actions: [SyncAction]

    public func count(_ matches: (SyncAction) -> Bool) -> Int { actions.filter(matches).count }
    public var created: Int { count { if case .create = $0 { true } else { false } } }
    public var updated: Int { count { if case .update = $0 { true } else if case .move = $0 { true } else { false } } }
    public var removed: Int { count { if case .remove = $0 { true } else { false } } }
    public var adopted: Int { count { if case .adopt = $0 { true } else { false } } }
    public var skipped: Int { count { if case .skip = $0 { true } else { false } } }
    /// Whether there is anything to write.
    public var hasWork: Bool { actions.contains { if case .skip = $0 { false } else { true } } }
}

/// Decides, without touching anything, what a sync does (ADR 0026). Pure: the items, the links and what the system store holds go in.
public enum SyncPlanner {
    /// An item is ready when it is active and does not wait in the Inbox (approved by the user, or sure enough by the Inbox rules).
    public static func isReady(_ item: Item) -> Bool { item.status == .active && !item.needsReview }

    public static func plan(sources: [SyncSource], links: [String: SyncLink], lookup: (SyncLink) -> StoredEntry?, settings: SyncSettings) -> SyncPlan {
        var actions: [SyncAction] = []
        for source in sources {
            if let action = decide(source, link: links[source.item.id], lookup: lookup, settings: settings) { actions.append(action) }
        }
        return SyncPlan(actions: actions)
    }

    private static func tooOld(_ item: Item, _ settings: SyncSettings) -> Bool {
        guard let moment = ItemListModel.moment(item) else { return false }
        return moment < settings.now.addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
    }

    private static func decide(_ source: SyncSource, link: SyncLink?, lookup: (SyncLink) -> StoredEntry?, settings: SyncSettings) -> SyncAction? {
        let item = source.item
        let kind = SyncRender.kind(of: item)
        let ready = isReady(item)
        let rendered = SyncRender.render(source)

        guard let link else {
            guard ready else { return .skip(itemID: item.id, reason: item.status == .active ? .inbox : .notReady) }
            return createAction(source, rendered, kind, settings)
        }

        switch link.state {
        case .removedByUser:
            return ready ? .skip(itemID: item.id, reason: .removedByUser) : nil
        case .completed:
            return .skip(itemID: item.id, reason: .completed)
        case .removed:
            // Removed because it was dismissed or merged away; restoring the item writes it again.
            guard ready else { return nil }
            return createAction(source, rendered, kind, settings)
        case .synced, .failed:
            break
        }

        // The item left Memorri's list: its entry goes.
        if item.status == .dismissed || item.status == .merged {
            return .remove(itemID: item.id, reason: item.status == .merged ? "merged" : "dismissed")
        }
        // Back in the Inbox after a change: the entry stays as it is until the item is approved again.
        guard ready else { return .skip(itemID: item.id, reason: .inbox) }

        guard let stored = lookup(link) else { return .markRemovedByUser(itemID: item.id, reason: "deleted") }
        let wanted = settings.containerID(for: kind)
        if stored.containerID != link.containerID && stored.containerID != wanted { return .markRemovedByUser(itemID: item.id, reason: "moved") }
        if kind == .reminder, stored.completed { return .complete(itemID: item.id) }

        let edits = SyncRender.outsideEdits(last: link.fields, now: stored.entry, contextName: source.contextName)
        if !edits.isEmpty { return .adopt(itemID: item.id, fields: edits) }

        guard let wanted else { return .skip(itemID: item.id, reason: kind == .event ? .noCalendar : .noList) }
        if link.containerID != wanted { return .move(itemID: item.id, entry: rendered, from: link.containerID, to: wanted) }
        if SyncRender.hash(rendered) == link.hash && link.hashVersion == SyncRender.hashVersion && link.state == .synced {
            return .skip(itemID: item.id, reason: .unchanged)
        }
        return .update(itemID: item.id, entry: rendered, changed: SyncRender.changedFields(from: link.fields, to: rendered))
    }

    private static func createAction(_ source: SyncSource, _ rendered: RenderedEntry, _ kind: SyncEntryKind, _ settings: SyncSettings) -> SyncAction {
        let item = source.item
        guard let container = settings.containerID(for: kind) else { return .skip(itemID: item.id, reason: kind == .event ? .noCalendar : .noList) }
        if kind == .event, item.start == nil { return .skip(itemID: item.id, reason: .noDate) }
        if tooOld(item, settings) { return .skip(itemID: item.id, reason: .tooOld) }
        return .create(itemID: item.id, entry: rendered, containerID: container)
    }
}
