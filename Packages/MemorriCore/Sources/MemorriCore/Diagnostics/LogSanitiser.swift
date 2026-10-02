import Foundation

/// One line of the app's own log.
public struct LogLine: Sendable, Equatable {
    public let category: String
    public let level: String
    public let text: String
    public let date: Date

    public init(category: String, level: String, text: String, date: Date) { self.category = category; self.level = level; self.text = text; self.date = date }
}

/// Decides which log lines and failure reasons may go into a diagnostic report (spec 010 FR-025, research R8). The report is built from figures, so this
/// is the second wall: it drops whatever could hold the library's content.
public enum LogSanitiser {
    /// The log categories whose lines are written by Memorri's own code to describe counts and states.
    public static let categories: Set<String> = ["storage", "permission", "capture", "sync", "search", "reconcile", "ollama", "extraction", "windows", "trial", "reread",
                                                  "lifecycle", "evidence", "cancellation", "analysis", "shortcut", "backup", "notifications"]
    public static let longestLine = 12
    public static let shortestSecret = 4

    public static func keep(_ line: LogLine, sensitive: Set<String>) -> Bool {
        guard categories.contains(line.category), isClean(line.text, sensitive: sensitive) else { return false }
        return true
    }

    /// A failure reason, or a note saying it was removed because it may hold content.
    public static func sanitiseReason(_ reason: String, sensitive: Set<String>) -> String {
        isClean(reason, sensitive: sensitive) ? reason : "(removed: it may contain content from the library)"
    }

    /// True when the text names none of the library's strings (compared in lower case, strings of at least four characters) and is short enough to be a log line.
    static func isClean(_ text: String, sensitive: Set<String>) -> Bool {
        if text.split(whereSeparator: \.isWhitespace).count > longestLine { return false }
        let lower = text.lowercased()
        return !sensitive.contains { $0.count >= shortestSecret && lower.contains($0) }
    }
}
