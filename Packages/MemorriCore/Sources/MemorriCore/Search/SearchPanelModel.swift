import Foundation

/// What the quick-search panel says and does, as pure functions (spec 007): row text for VoiceOver and the list, the empty and waiting messages,
/// the rows the keyboard walks through. The SwiftUI view only draws what this returns.
public enum SearchPanelModel {
    public enum Row: Sendable, Equatable {
        case item(String)
        case capture(String)
        case showMoreItems
        case showMoreCaptures
    }

    public enum Target: Sendable, Equatable {
        case openItem(String)
        case openCapture(String)
        case showMoreItems
        case showMoreCaptures
    }

    // MARK: Text

    static func kindName(_ kind: FindingKind) -> String {
        switch kind {
        case .appointment: "Appointment"
        case .task: "Task"
        case .reminder: "Reminder"
        case .deadline: "Deadline"
        }
    }

    public static func dateText(_ date: Date, timezone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timezone
        formatter.dateFormat = "EEE d MMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    /// The row as one sentence: `Appointment, <title>, <date>, <context>, dismissed, needs review, matched in alias`.
    public static func rowText(_ hit: ItemHit, contextName: String?, timezone: TimeZone = .current, locale: Locale = .current) -> String {
        var parts = [kindName(hit.kind), hit.title.text]
        if let date = hit.date { parts.append(dateText(date, timezone: timezone, locale: locale)) }
        if let contextName { parts.append(contextName) }
        if hit.status == .dismissed { parts.append("dismissed") }
        if hit.needsReview { parts.append("needs review") }
        if hit.matchedIn != .title { parts.append("matched in \(hit.matchedIn.rawValue)") }
        return parts.joined(separator: ", ")
    }

    /// `<app> — <title>`, just the application or the title when the other is missing, nil when there is no window.
    public static func windowText(app: String?, title: String?) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        switch (clean(app), clean(title)) {
        case let (app?, title?): return "\(app) — \(title)"
        case let (app?, nil): return app
        case let (nil, title?): return title
        case (nil, nil): return nil
        }
    }

    /// The row as one sentence: `Capture, <time>, <display>, <window>, <first matching line>`.
    public static func rowText(_ hit: CaptureHit, timezone: TimeZone = .current, locale: Locale = .current) -> String {
        var parts = ["Capture", dateText(hit.capturedAt, timezone: timezone, locale: locale)]
        if let display = hit.displayName, !display.isEmpty { parts.append(display) }
        if let window = windowText(app: hit.windowApp, title: hit.windowTitle) { parts.append(window) }
        if let line = hit.lines.first { parts.append(line.text.text) }
        return parts.joined(separator: ", ")
    }

    /// The active filters as short phrases, in a fixed order: kind, context, dates, dismissed.
    public static func filterTexts(_ query: SearchQuery, contextName: String?, timezone: TimeZone = .current, locale: Locale = .current) -> [String] {
        var texts: [String] = []
        if !query.kinds.isEmpty {
            let order: [(SearchQuery.Kinds, String)] = [(.appointments, "Appointments"), (.tasks, "Tasks"), (.reminders, "Reminders"), (.captures, "Captures")]
            texts.append("Kind: " + order.filter { query.kinds.contains($0.0) }.map(\.1).joined(separator: ", "))
        }
        switch query.context {
        case .any: break
        case .none: texts.append("No context")
        case .one: texts.append("Context: " + (contextName ?? "unknown"))
        }
        if let dates = query.dates {
            let formatter = DateFormatter()
            formatter.locale = locale; formatter.timeZone = timezone; formatter.dateFormat = "d MMM"
            texts.append("Dates: \(formatter.string(from: dates.lowerBound)) – \(formatter.string(from: dates.upperBound))")
        }
        if query.includeDismissed { texts.append("Including dismissed") }
        return texts
    }

    /// What the panel shows in place of results, or nil when there are results to show.
    public static func message(for query: SearchQuery, results: SearchResults, state: SearchState, contextName: String?) -> String? {
        if case .preparing(let done, let total) = state { return "Search is being prepared (\(done) of \(total))" }
        guard query.isSearchable else { return "Type at least two letters" }
        guard results.items.isEmpty, results.captures.isEmpty else { return nil }
        let filters = filterTexts(query, contextName: contextName)
        var text = "Nothing found" + (filters.isEmpty ? "" : " with " + filters.joined(separator: ", "))
        if results.waitingToBeAnalysed > 0 {
            let n = results.waitingToBeAnalysed
            text += ". \(n) \(n == 1 ? "capture is" : "captures are") still waiting to be analysed."
        } else if !filters.isEmpty {
            text += "."
        }
        return text
    }

    // MARK: Date filter

    /// The ready-made date ranges of the Date menu; each is whole days.
    public enum DatePreset: String, Sendable, CaseIterable {
        case today = "Today", last7Days = "Last 7 days", last30Days = "Last 30 days", thisMonth = "This month", next30Days = "Next 30 days"

        public func range(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
            let today = calendar.startOfDay(for: now)
            func end(of day: Date) -> Date { calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: day)) ?? day }
            func days(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today) ?? today }
            switch self {
            case .today: return today...end(of: today)
            case .last7Days: return days(-6)...end(of: today)
            case .last30Days: return days(-29)...end(of: today)
            case .next30Days: return today...end(of: days(30))
            case .thisMonth:
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
                let last = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? today
                return start...end(of: last)
            }
        }
    }

    /// A range the user picked: the earlier date first, from the start of its day to the end of the later one.
    public static func customRange(from: Date, to: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = min(from, to), last = max(from, to)
        let start = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: last)) ?? last
        return start...end
    }

    // MARK: Rows and keys

    public static func rows(_ results: SearchResults) -> [Row] {
        var rows = results.items.map { Row.item($0.id) }
        if results.moreItems { rows.append(.showMoreItems) }
        rows += results.captures.map { Row.capture($0.id) }
        if results.moreCaptures { rows.append(.showMoreCaptures) }
        return rows
    }

    /// The row after pressing up (-1) or down (+1); the first press selects the first row. Stays inside the list; nil when it is empty.
    public static func move(from selection: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selection else { return 0 }
        return min(max(selection + delta, 0), count - 1)
    }

    public static func target(rows: [Row], selection: Int?) -> Target? {
        guard let selection, rows.indices.contains(selection) else { return nil }
        switch rows[selection] {
        case .item(let id): return .openItem(id)
        case .capture(let id): return .openCapture(id)
        case .showMoreItems: return .showMoreItems
        case .showMoreCaptures: return .showMoreCaptures
        }
    }
}
