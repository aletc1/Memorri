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

    /// What the panel shows in place of results, or nil when there are results to show.
    public static func message(for query: SearchQuery, results: SearchResults, state: SearchState, contextName: String?) -> String? {
        if case .preparing(let done, let total) = state { return "Search is being prepared (\(done) of \(total))" }
        guard query.isSearchable else { return "Type at least two letters" }
        guard results.items.isEmpty, results.captures.isEmpty else { return nil }
        var text = "Nothing found"
        if results.waitingToBeAnalysed > 0 {
            let n = results.waitingToBeAnalysed
            text += ". \(n) \(n == 1 ? "capture is" : "captures are") still waiting to be analysed."
        }
        return text
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
