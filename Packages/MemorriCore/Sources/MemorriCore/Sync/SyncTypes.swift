import Foundation

public enum SyncEntryKind: String, Sendable, Equatable, Codable { case event, reminder }

public enum SyncAccess: Sendable, Equatable { case notDetermined, allowed, denied }

/// A calendar or a Reminders list the user could choose, with the account it belongs to.
public struct SyncContainer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let account: String
    public let kind: SyncEntryKind
    /// The container already holds entries (it is not empty); Memorri never touches those it did not make.
    public let holdsOtherEntries: Bool

    public init(id: String, name: String, account: String, kind: SyncEntryKind, holdsOtherEntries: Bool = false) {
        self.id = id; self.name = name; self.account = account; self.kind = kind; self.holdsOtherEntries = holdsOtherEntries
    }
}

/// What Memorri writes for one item: the same fields whatever the store, so it can be compared and hashed.
public struct RenderedEntry: Sendable, Equatable, Codable {
    public var kind: SyncEntryKind
    public var title: String
    public var start: Date?
    public var end: Date?
    public var allDay: Bool
    public var timezone: String
    public var location: String?
    public var due: Date?
    public var alarm: Date?
    public var notes: String

    public init(kind: SyncEntryKind, title: String, start: Date? = nil, end: Date? = nil, allDay: Bool = false, timezone: String = "UTC",
                location: String? = nil, due: Date? = nil, alarm: Date? = nil, notes: String = "") {
        self.kind = kind; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.timezone = timezone
        self.location = location; self.due = due; self.alarm = alarm; self.notes = notes
    }
}

/// An entry as the system store holds it now.
public struct StoredEntry: Sendable, Equatable {
    public let id: String
    public let containerID: String
    public var entry: RenderedEntry
    /// A reminder marked completed.
    public var completed: Bool

    public init(id: String, containerID: String, entry: RenderedEntry, completed: Bool = false) {
        self.id = id; self.containerID = containerID; self.entry = entry; self.completed = completed
    }
}

public enum SyncError: Error, Equatable {
    /// The entry or the target is not in the calendar or list the user chose (ADR 0026).
    case outsideTarget(String)
    /// Nothing is chosen for this kind, so nothing is written.
    case noTarget(SyncEntryKind)
    /// An identifier Memorri did not write.
    case notOurs(String)
    case noAccess(SyncEntryKind)
    case failed(String)
}

/// The part of the system's event store that sync needs, so the engine is tested with a fake and EventKit stays behind one adapter.
public protocol EventStoring: Sendable {
    func access(for kind: SyncEntryKind) -> SyncAccess
    func requestAccess(for kind: SyncEntryKind) async -> SyncAccess
    /// The calendars (events) or lists (reminders) the user can write to.
    func containers(for kind: SyncEntryKind) -> [SyncContainer]
    /// The entry with this identifier, nil when it no longer exists.
    func entry(id: String, kind: SyncEntryKind) -> StoredEntry?
    func create(_ entry: RenderedEntry, in containerID: String) throws -> String
    func update(id: String, _ entry: RenderedEntry) throws
    func delete(id: String, kind: SyncEntryKind) throws
}

public enum SyncLinkState: String, Sendable, Equatable {
    case synced, completed, failed
    case removedByUser = "removed_by_user"
    /// Removed by Memorri because the item was dismissed or merged away.
    case removed
}

/// The record of an entry Memorri made (`sync_links`).
public struct SyncLink: Sendable, Equatable {
    public let itemID: String
    public let kind: SyncEntryKind
    public var ekID: String
    public var containerID: String
    public var hash: String
    public var hashVersion: Int
    /// The fields as last written, to tell an edit made outside from Memorri's own change.
    public var fields: RenderedEntry
    public var state: SyncLinkState
    public var failure: String?
    public var syncedAt: Date

    public init(itemID: String, kind: SyncEntryKind, ekID: String, containerID: String, hash: String, hashVersion: Int, fields: RenderedEntry,
                state: SyncLinkState, failure: String? = nil, syncedAt: Date) {
        self.itemID = itemID; self.kind = kind; self.ekID = ekID; self.containerID = containerID; self.hash = hash; self.hashVersion = hashVersion
        self.fields = fields; self.state = state; self.failure = failure; self.syncedAt = syncedAt
    }
}

/// The user's choices and the clock for one planning.
public struct SyncSettings: Sendable, Equatable {
    public var calendarID: String?
    public var listID: String?
    public var now: Date
    /// Items whose moment is older than this are not written.
    public var maxAgeDays: Int

    public init(calendarID: String?, listID: String?, now: Date, maxAgeDays: Int = 90) {
        self.calendarID = calendarID; self.listID = listID; self.now = now; self.maxAgeDays = maxAgeDays
    }

    public func containerID(for kind: SyncEntryKind) -> String? { kind == .event ? calendarID : listID }
}

/// An item with what sync needs to write it.
public struct SyncSource: Sendable, Equatable {
    public let item: Item
    public let contextName: String?
    /// `Seen 14 Oct 09:12 · Calendar — Week`, newest first.
    public let evidence: [String]

    public init(item: Item, contextName: String? = nil, evidence: [String] = []) { self.item = item; self.contextName = contextName; self.evidence = evidence }
}
