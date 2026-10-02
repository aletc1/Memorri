import EventKit
import Foundation
import MemorriCore

/// The one place Memorri talks to EventKit (ADR 0026). It does what it is told with identifiers; the `ScopedEventStore` in front of it decides what
/// may be written. All-day entries hold calendar days as midnight UTC (`SyncRender.day`), turned into the local day here and back on reading.
final class EventKitStore: EventStoring, @unchecked Sendable {
    private let store = EKEventStore()

    /// Fires when Calendar or Reminders changed, whoever changed it.
    var changes: NotificationCenter { .default }
    static let changed = Notification.Name.EKEventStoreChanged

    private func type(_ kind: SyncEntryKind) -> EKEntityType { kind == .event ? .event : .reminder }

    // MARK: Access

    func access(for kind: SyncEntryKind) -> SyncAccess {
        switch EKEventStore.authorizationStatus(for: type(kind)) {
        case .fullAccess: .allowed
        case .notDetermined: .notDetermined
        default: .denied                       // denied, restricted, or write-only (reading is needed to find edits and removals)
        }
    }

    func requestAccess(for kind: SyncEntryKind) async -> SyncAccess {
        do {
            if kind == .event { _ = try await store.requestFullAccessToEvents() } else { _ = try await store.requestFullAccessToReminders() }
        } catch {}
        return access(for: kind)
    }

    // MARK: Targets

    func containers(for kind: SyncEntryKind) -> [SyncContainer] {
        guard access(for: kind) == .allowed else { return [] }
        return store.calendars(for: type(kind)).filter(\.allowsContentModifications).map { calendar in
            SyncContainer(id: calendar.calendarIdentifier, name: calendar.title, account: calendar.source?.title ?? "", kind: kind)
        }
        .sorted { ($0.account, $0.name) < ($1.account, $1.name) }
    }

    func containerExists(id: String, kind: SyncEntryKind) -> Bool {
        guard access(for: kind) == .allowed, let calendar = store.calendar(withIdentifier: id) else { return false }
        return calendar.allowsContentModifications && calendar.allowedEntityTypes.contains(kind == .event ? .event : .reminder)
    }

    /// Whether a calendar holds events within a year either way (a sign it is in use), stopping at the first one. Lists are not checked: that needs an
    /// asynchronous fetch. Not for the main thread.
    func holdsEntries(inContainer id: String, kind: SyncEntryKind) -> Bool {
        guard kind == .event, access(for: .event) == .allowed, let calendar = store.calendar(withIdentifier: id) else { return false }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-365 * 86_400), end: now.addingTimeInterval(365 * 86_400), calendars: [calendar])
        var found = false
        store.enumerateEvents(matching: predicate) { _, stop in found = true; stop.pointee = true }
        return found
    }

    // MARK: Reading

    func entry(id: String, kind: SyncEntryKind) -> StoredEntry? {
        guard access(for: kind) == .allowed else { return nil }
        if kind == .event {
            guard let event = store.event(withIdentifier: id), let calendar = event.calendar else { return nil }
            return StoredEntry(id: id, containerID: calendar.calendarIdentifier, entry: Self.entry(event))
        }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder, let calendar = reminder.calendar else { return nil }
        return StoredEntry(id: id, containerID: calendar.calendarIdentifier, entry: Self.entry(reminder), completed: reminder.isCompleted)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    /// The calendar day of a local date as midnight UTC.
    private static func floatingDay(_ date: Date) -> Date { SyncRender.day(date, in: .current) }

    private static func entry(_ event: EKEvent) -> RenderedEntry {
        let allDay = event.isAllDay
        let begin: Date? = event.startDate, finish: Date? = event.endDate
        let start = begin.map { allDay ? floatingDay($0) : $0 }
        var end = (finish ?? begin).map { allDay ? floatingDay($0) : $0 }
        if !allDay { end = finish }
        if allDay, let value = end, let start, value <= start { end = nil }
        return RenderedEntry(kind: .event, title: event.title ?? "", start: start, end: end, allDay: allDay, timezone: event.timeZone?.identifier ?? TimeZone.current.identifier,
                             location: event.location.flatMap { $0.isEmpty ? nil : $0 }, notes: event.notes ?? "")
    }

    private static func entry(_ reminder: EKReminder) -> RenderedEntry {
        var due: Date?
        var allDay = false
        if let parts = reminder.dueDateComponents {
            allDay = parts.hour == nil
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = allDay ? utc : (parts.timeZone ?? .current)
            due = calendar.date(from: parts)
        }
        return RenderedEntry(kind: .reminder, title: reminder.title ?? "", allDay: allDay, timezone: reminder.dueDateComponents?.timeZone?.identifier ?? TimeZone.current.identifier,
                             due: due, alarm: reminder.alarms?.compactMap(\.absoluteDate).first, notes: reminder.notes ?? "")
    }

    // MARK: Writing

    func create(_ entry: RenderedEntry, in containerID: String) throws -> String {
        guard let calendar = store.calendar(withIdentifier: containerID) else { throw SyncError.failed("the calendar or list is gone") }
        if entry.kind == .event {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            Self.fill(event, entry)
            try store.save(event, span: .thisEvent, commit: true)
            guard let id = event.eventIdentifier else { throw SyncError.failed("no identifier for the new event") }
            return id
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        Self.fill(reminder, entry)
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func update(id: String, _ entry: RenderedEntry) throws {
        if entry.kind == .event {
            guard let event = store.event(withIdentifier: id) else { throw SyncError.failed("the event is gone") }
            Self.fill(event, entry)
            try store.save(event, span: .thisEvent, commit: true)
        } else {
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw SyncError.failed("the reminder is gone") }
            Self.fill(reminder, entry)
            try store.save(reminder, commit: true)
        }
    }

    func delete(id: String, kind: SyncEntryKind) throws {
        if kind == .event {
            guard let event = store.event(withIdentifier: id) else { return }
            try store.remove(event, span: .thisEvent, commit: true)
        } else {
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
            try store.remove(reminder, commit: true)
        }
    }

    // MARK: Fields

    private static func fill(_ event: EKEvent, _ entry: RenderedEntry) {
        event.title = entry.title
        event.isAllDay = entry.allDay
        if entry.allDay, let start = entry.start {
            let first = SyncRender.moment(ofDay: start, in: .current)
            event.startDate = first
            event.endDate = entry.end.map { SyncRender.moment(ofDay: $0, in: .current) } ?? first
        } else {
            event.timeZone = TimeZone(identifier: entry.timezone)
            event.startDate = entry.start
            event.endDate = entry.end ?? entry.start?.addingTimeInterval(3600)
        }
        event.location = entry.location
        event.notes = entry.notes
    }

    private static func fill(_ reminder: EKReminder, _ entry: RenderedEntry) {
        reminder.title = entry.title
        reminder.notes = entry.notes
        if let due = entry.due {
            var calendar = Calendar(identifier: .gregorian)
            if entry.allDay {
                calendar.timeZone = utc
                reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: due)
            } else {
                let zone = TimeZone(identifier: entry.timezone) ?? .current
                calendar.timeZone = zone
                var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
                parts.timeZone = zone
                reminder.dueDateComponents = parts
            }
        } else {
            reminder.dueDateComponents = nil
        }
        for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
        if let alarm = entry.alarm { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
    }
}
