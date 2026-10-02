import CryptoKit
import Foundation

/// How an item becomes an entry of Calendar or Reminders, and the hash that says whether it changed (spec 009 FR-005, FR-006, ADR 0026).
public enum SyncRender {
    /// Raised when a field joins the entry, so every link is judged afresh.
    public static let hashVersion = 1
    public static let evidenceLines = 3

    public static func link(itemID: String) -> String { "memorri://item/\(itemID)" }

    public static func kind(of item: Item) -> SyncEntryKind { item.family == .event ? .event : .reminder }

    public static func title(_ item: Item, context: String?) -> String {
        guard let context, !context.trimmingCharacters(in: .whitespaces).isEmpty else { return item.title }
        return "[\(context)] \(item.title)"
    }

    public static func render(_ source: SyncSource) -> RenderedEntry {
        let item = source.item
        let title = title(item, context: source.contextName)
        var notes = ["Made by Memorri"]
        if !item.people.isEmpty { notes.append("With: " + item.people.joined(separator: ", ")) }
        let kind = kind(of: item)
        if kind == .reminder, let place = item.place, !place.isEmpty { notes.append("Place: \(place)") }
        notes += source.evidence.prefix(evidenceLines).map { "Seen: \($0)" }
        notes.append(link(itemID: item.id))
        if kind == .event {
            let end = item.end ?? (item.allDay ? nil : item.start.map { $0.addingTimeInterval(3600) })
            return RenderedEntry(kind: .event, title: title, start: item.start, end: end, allDay: item.allDay, timezone: item.timezone,
                                 location: item.place.flatMap { $0.isEmpty ? nil : $0 }, notes: notes.joined(separator: "\n"))
        }
        return RenderedEntry(kind: .reminder, title: title, allDay: item.allDay, timezone: item.timezone, due: item.due ?? item.start, alarm: item.remind,
                             notes: notes.joined(separator: "\n"))
    }

    /// A hash of every field that is written, stable across launches.
    public static func hash(_ entry: RenderedEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var rounded = entry
        func whole(_ d: Date?) -> Date? { d.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) } }
        rounded.start = whole(entry.start); rounded.end = whole(entry.end); rounded.due = whole(entry.due); rounded.alarm = whole(entry.alarm)
        let data = (try? encoder.encode(rounded)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The names of the fields that differ between two entries (for a preview and the run's detail).
    public static func changedFields(from old: RenderedEntry, to new: RenderedEntry) -> [String] {
        func same(_ a: Date?, _ b: Date?) -> Bool { switch (a, b) { case (nil, nil): true; case let (x?, y?): abs(x.timeIntervalSince(y)) < 1; default: false } }
        var out: [String] = []
        if old.title != new.title { out.append("title") }
        if !same(old.start, new.start) { out.append("start") }
        if !same(old.end, new.end) { out.append("end") }
        if old.allDay != new.allDay { out.append("all day") }
        if (old.location ?? "") != (new.location ?? "") { out.append("place") }
        if !same(old.due, new.due) { out.append("due") }
        if !same(old.alarm, new.alarm) { out.append("alarm") }
        if old.notes != new.notes { out.append("notes") }
        return out
    }

    /// What the user changed in Calendar or Reminders since Memorri last wrote the entry, as values for the item (spec 009 FR-009). The title
    /// loses the context prefix Memorri adds; notes and the alarm are not taken. Empty when nothing the item holds was changed.
    public static func outsideEdits(last: RenderedEntry, now: RenderedEntry, contextName: String?) -> [ItemField: JSONValue] {
        func same(_ a: Date?, _ b: Date?) -> Bool { switch (a, b) { case (nil, nil): true; case let (x?, y?): abs(x.timeIntervalSince(y)) < 1; default: false } }
        var out: [ItemField: JSONValue] = [:]
        if last.title != now.title {
            var text = now.title
            if let context = contextName, !context.isEmpty, text.hasPrefix("[\(context)] ") { text.removeFirst("[\(context)] ".count) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[.title] = .string(trimmed) }
        }
        if last.kind == .event {
            if let start = now.start, !same(last.start, start) { out[.start] = .date(start) }
            if let end = now.end, !same(last.end, end) { out[.end] = .date(end) }
            if last.allDay != now.allDay { out[.allDay] = .bool(now.allDay) }
            if (last.location ?? "") != (now.location ?? "") { out[.place] = (now.location ?? "").isEmpty ? .null : .string(now.location!) }
        } else if let due = now.due, !same(last.due, due) {
            out[.due] = .date(due)
        }
        return out
    }
}
