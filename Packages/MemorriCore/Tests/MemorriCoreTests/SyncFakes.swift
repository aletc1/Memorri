import Foundation
@testable import MemorriCore

/// A system event store in memory: calendars and lists, entries, and a record of every write.
final class FakeEventStore: EventStoring, @unchecked Sendable {
    struct Write: Equatable { let op: String; let id: String; let container: String }

    private let lock = NSLock()
    private var _entries: [String: StoredEntry] = [:]
    private var _writes: [Write] = []
    private var counter = 0
    var calendars: [SyncContainer] = [SyncContainer(id: "cal-memorri", name: "Memorri", account: "iCloud", kind: .event),
                                      SyncContainer(id: "cal-work", name: "Work", account: "Exchange", kind: .event, holdsOtherEntries: true),
                                      SyncContainer(id: "cal-personal", name: "Personal", account: "iCloud", kind: .event, holdsOtherEntries: true)]
    var lists: [SyncContainer] = [SyncContainer(id: "list-memorri", name: "Memorri", account: "iCloud", kind: .reminder),
                                  SyncContainer(id: "list-home", name: "Home", account: "iCloud", kind: .reminder, holdsOtherEntries: true)]
    var eventAccess: SyncAccess = .allowed
    var reminderAccess: SyncAccess = .allowed
    /// Titles (as written) the store refuses to create or update.
    var failTitles: Set<String> = []

    var entries: [String: StoredEntry] { lock.withLock { _entries } }
    var writes: [Write] { lock.withLock { _writes } }
    func clearWrites() { lock.withLock { _writes = [] } }

    func access(for kind: SyncEntryKind) -> SyncAccess { kind == .event ? eventAccess : reminderAccess }
    func requestAccess(for kind: SyncEntryKind) async -> SyncAccess { access(for: kind) }
    func containers(for kind: SyncEntryKind) -> [SyncContainer] { kind == .event ? calendars : lists }
    func entry(id: String, kind: SyncEntryKind) -> StoredEntry? { lock.withLock { _entries[id].flatMap { $0.entry.kind == kind ? $0 : nil } } }

    func create(_ entry: RenderedEntry, in containerID: String) throws -> String {
        if failTitles.contains(entry.title) { throw SyncError.failed("the store refused") }
        return lock.withLock {
            counter += 1
            let id = (entry.kind == .event ? "E" : "R") + String(counter)
            _entries[id] = StoredEntry(id: id, containerID: containerID, entry: entry)
            _writes.append(Write(op: "create", id: id, container: containerID))
            return id
        }
    }

    func update(id: String, _ entry: RenderedEntry) throws {
        if failTitles.contains(entry.title) { throw SyncError.failed("the store refused") }
        lock.withLock {
            if var stored = _entries[id] { stored.entry = entry; _entries[id] = stored; _writes.append(Write(op: "update", id: id, container: stored.containerID)) }
        }
    }

    func delete(id: String, kind: SyncEntryKind) throws {
        lock.withLock { if let stored = _entries.removeValue(forKey: id) { _writes.append(Write(op: "delete", id: id, container: stored.containerID)) } }
    }

    // What a person does in Calendar or Reminders: nothing here is a write by Memorri.

    func edit(_ id: String, _ change: (inout StoredEntry) -> Void) { lock.withLock { if var stored = _entries[id] { change(&stored); _entries[id] = stored } } }
    func remove(_ id: String) { lock.withLock { _ = _entries.removeValue(forKey: id) } }

    /// An event of the user's own in a calendar, which Memorri must never touch.
    @discardableResult
    func seedForeign(in container: String, title: String, kind: SyncEntryKind = .event) -> String {
        lock.withLock {
            counter += 1
            let id = "F\(counter)"
            _entries[id] = StoredEntry(id: id, containerID: container, entry: RenderedEntry(kind: kind, title: title, start: Date(timeIntervalSince1970: 1_800_000_000)))
            return id
        }
    }
}

extension RenderedEntry {
    static func sample(_ kind: SyncEntryKind = .event, title: String = "Standup") -> RenderedEntry {
        RenderedEntry(kind: kind, title: title, start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600), notes: "Made by Memorri")
    }
}

func syncItem(_ id: String = "i1", kind: FindingKind = .appointment, title: String = "Standup", status: ItemStatus = .active, needsReview: Bool = false,
              start: Date? = Date(timeIntervalSince1970: 1_800_000_000), end: Date? = nil, due: Date? = nil, allDay: Bool = false, place: String? = nil,
              people: [String] = [], remind: Date? = nil, approved: Bool = false) -> Item {
    Item(id: id, kind: kind, status: status, title: title, allDay: allDay, start: start, end: end, due: due, remind: remind, timezone: "UTC", people: people,
         place: place, confidence: 0.9, firstSeen: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
         needsReview: needsReview, approvedAt: approved ? Date(timeIntervalSince1970: 1_700_000_100) : nil)
}
