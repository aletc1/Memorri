import Foundation

/// The only door sync writes through (ADR 0026, spec 009 FR-019). It refuses every create, update and delete that is not in the calendar or
/// list the user chose, refuses events when no calendar is chosen (reminders when no list is), and only touches entries Memorri made.
public struct ScopedEventStore: EventStoring {
    private let base: any EventStoring
    private let calendarID: String?
    private let listID: String?
    private let isOurs: @Sendable (String) -> Bool
    private let alsoRemovableFrom: Set<String>

    /// `isOurs` says whether an identifier is in `sync_links`. `alsoRemovableFrom` lists the earlier calendar and list while the user has
    /// confirmed moving Memorri's entries to new ones; entries there may be deleted, never written.
    public init(base: any EventStoring, calendarID: String?, listID: String?, alsoRemovableFrom: Set<String> = [],
                isOurs: @escaping @Sendable (String) -> Bool) {
        self.base = base; self.calendarID = calendarID; self.listID = listID; self.alsoRemovableFrom = alsoRemovableFrom; self.isOurs = isOurs
    }

    private func chosen(_ kind: SyncEntryKind) -> String? { kind == .event ? calendarID : listID }

    // Reads pass through: they change nothing.
    public func access(for kind: SyncEntryKind) -> SyncAccess { base.access(for: kind) }
    public func requestAccess(for kind: SyncEntryKind) async -> SyncAccess { await base.requestAccess(for: kind) }
    public func containers(for kind: SyncEntryKind) -> [SyncContainer] { base.containers(for: kind) }
    public func entry(id: String, kind: SyncEntryKind) -> StoredEntry? { base.entry(id: id, kind: kind) }
    public func containerExists(id: String, kind: SyncEntryKind) -> Bool { base.containerExists(id: id, kind: kind) }
    public func holdsEntries(inContainer id: String, kind: SyncEntryKind) -> Bool { base.holdsEntries(inContainer: id, kind: kind) }

    public func create(_ entry: RenderedEntry, in containerID: String) throws -> String {
        guard let target = chosen(entry.kind) else { throw SyncError.noTarget(entry.kind) }
        guard containerID == target else { throw SyncError.outsideTarget(containerID) }
        guard base.containers(for: entry.kind).contains(where: { $0.id == target }) else { throw SyncError.outsideTarget(target) }
        return try base.create(entry, in: target)
    }

    public func update(id: String, _ entry: RenderedEntry) throws {
        guard let target = chosen(entry.kind) else { throw SyncError.noTarget(entry.kind) }
        guard isOurs(id) else { throw SyncError.notOurs(id) }
        guard let stored = base.entry(id: id, kind: entry.kind) else { throw SyncError.failed("the entry no longer exists") }
        guard stored.containerID == target else { throw SyncError.outsideTarget(stored.containerID) }
        try base.update(id: id, entry)
    }

    public func delete(id: String, kind: SyncEntryKind) throws {
        guard isOurs(id) else { throw SyncError.notOurs(id) }
        guard let stored = base.entry(id: id, kind: kind) else { return }                 // already gone: nothing to delete
        guard stored.containerID == chosen(kind) || alsoRemovableFrom.contains(stored.containerID) else { throw SyncError.outsideTarget(stored.containerID) }
        try base.delete(id: id, kind: kind)
    }
}
